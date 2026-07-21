//===----------------------------------------------------------------------===//
//
//  FromRequest.swift / FromRequestParts.swift
//  StarlightCore
//
//  Direct port of `axum_core::extract::{FromRequest, FromRequestParts}`.
//
//  Extractors: types that decompose a `Request` into handler
//  arguments. Each extractor is one positional handler parameter.
//  Conforming to `FromRequestParts` reads from the head of the
//  request (method, URI, headers, extensions) and is cheap; conforming
//  to `FromRequest` may consume the body (e.g. `Json<T>`, `Bytes`).
//
//  In axum, extractors that consume the body must be the *last*
//  positional argument of the handler — the body is moved out of the
//  request when the extractor runs. We model the same rule via the
//  handler adapters (see HandlerService.swift).
//
//  ─── Rejection model ─────────────────────────────────────────────────
//
//  axum returns `Result<Self, Self::Rejection>` where `Self::Rejection:
//  IntoResponse`. In Swift, `Result`'s `Failure` must be `Error`,
//  which makes that composition awkward. We instead throw a
//  single concrete `ExtractionRejection` error type that wraps a
//  `Response<Body>`. Concrete extractors build the appropriate
//  4xx `Response` inline and throw it. The dispatcher catches the
//  rejection and uses the embedded `Response` directly. This is the
//  Swift-idiomatic equivalent of axum's typed rejection pipeline
//  without the Error-vs-IntoResponse conformance conflict.
//
//===----------------------------------------------------------------------===//

import Foundation
import StarlightHTTP
import StarlightTower

/// Thrown by extractors on a 4xx rejection. Carries the `Response`
/// that should be returned to the client.
public struct ExtractionRejection: Error, Sendable {
    public let response: StarlightHTTP.Response<Body>

    @inlinable public init(_ response: StarlightHTTP.Response<Body>) {
        self.response = response
    }

    @inlinable public init(
        _ reason: String,
        status: StatusCode = .badRequest
    ) {
        self.response = StarlightHTTP.Response<Body>.plain(reason, status: status)
    }
}

/// The split-out parts of a `Request` that `FromRequestParts` reads.
///
/// axum calls this `RequestParts` — the request minus its body. We
/// mirror it so that an extractor that only needs headers (e.g.
/// `TypedHeader<T>`, `Query<T>`, `State<S>`) does not need to take
/// ownership of the body, leaving it available for a later
/// body-consuming extractor.
public struct RequestParts<B: Sendable>: Sendable {
    public var method: Method
    public var uri: Uri
    public var version: Version
    public var headers: HeaderMap
    public var extensions: Extensions
    /// Borrowed view of the body — present iff no prior extractor has
    /// consumed it via `FromRequest`. `nil` after the body has been
    /// moved out. The `FromRequest` extractor asserts / replaces this.
    public var body: B?

    @inlinable
    public init(_ request: consuming StarlightHTTP.Request<B>) {
        self.method = request.method
        self.uri = request.uri
        self.version = request.version
        self.headers = request.headers
        self.extensions = request.extensions
        self.body = request.body
    }
}

/// Extractor from `RequestParts` — does not consume the body.
///
/// Direct port of `axum_core::extract::FromRequestParts`. Implementations:
/// `State<S>`, `Path<T>`, `Query<T>`, `HeaderMap`, `Method`, `Uri`,
/// `Extensions`, `ConnectInfo<Addr>`, typed headers.
public protocol FromRequestParts: Sendable {
    /// The app state type. `AnySendable` for extractors that don't need state.
    associatedtype State: Sendable

    /// Extract from the request parts. Throws `ExtractionRejection`
    /// on a 4xx rejection.
    ///
    /// The state is passed by `borrowing` — most state-less extractors
    /// (Path, Query) ignore it; stateful ones (`State<S>`) only read it.
    static func fromRequestParts(
        _ parts: inout RequestParts<Body>,
        state: borrowing State
    ) async throws -> Self
}

/// Extractor from the full `Request` — may consume the body.
///
/// Direct port of `axum_core::extract::FromRequest`. Implementations:
/// `Body`, `Bytes`, `String`, `Json<T>`, `Form<T>`.
///
/// axum requires body-consuming extractors to be the *last* positional
/// argument of a handler; the body is moved out of the request when
/// the extractor runs.
public protocol FromRequest: Sendable {
    associatedtype State: Sendable

    /// Extract from the full request, consuming the body if needed.
    /// Throws `ExtractionRejection` on a 4xx rejection.
    static func fromRequest(
        _ request: consuming StarlightHTTP.Request<Body>,
        state: borrowing State
    ) async throws -> Self
}

// ── Default conformances for trivial types ────────────────────────

/// `Method` is an extractor — yields the request's method.
extension Method: FromRequestParts {
    public typealias State = AnySendable

    @inlinable
    public static func fromRequestParts(
        _ parts: inout RequestParts<Body>,
        state: borrowing AnySendable
    ) async throws -> Method {
        parts.method
    }
}

/// `Uri` is an extractor — yields the request's URI.
extension Uri: FromRequestParts {
    public typealias State = AnySendable

    @inlinable
    public static func fromRequestParts(
        _ parts: inout RequestParts<Body>,
        state: borrowing AnySendable
    ) async throws -> Uri {
        parts.uri
    }
}

/// `HeaderMap` is an extractor — yields the request's headers
/// (moved out of parts).
extension HeaderMap: FromRequestParts {
    public typealias State = AnySendable

    @inlinable
    public static func fromRequestParts(
        _ parts: inout RequestParts<Body>,
        state: borrowing AnySendable
    ) async throws -> HeaderMap {
        parts.headers
    }
}

/// `Body` is a body-consuming extractor — yields the request body
/// (moved out of the request).
extension Body: FromRequest {
    public typealias State = AnySendable

    @inlinable
    public static func fromRequest(
        _ request: consuming StarlightHTTP.Request<Body>,
        state: borrowing AnySendable
    ) async throws -> Body {
        request.body
    }
}

/// `String` is a body-consuming extractor — UTF-8 decodes the body.
extension String: FromRequest {
    public typealias State = AnySendable

    public static func fromRequest(
        _ request: consuming StarlightHTTP.Request<Body>,
        state: borrowing AnySendable
    ) async throws -> String {
        String(decoding: request.body.bytes, as: UTF8.self)
    }
}

// ── Placeholder state type ────────────────────────────────────────

/// Placeholder type-erased state for stateless extractors.
/// Real apps supply their own `State` type to `Router<AppState>`.
@frozen
public struct AnySendable: Sendable {
    @inlinable public init() {}
}
