//===----------------------------------------------------------------------===//
//
//  Extension.swift
//  StarlightCore
//
//  Direct port of `axum::extension::Extension<T>`.
//
//  Three roles (exactly like axum):
//    1. Extractor — reads T from request.extensions
//    2. Layer — inserts T into every request's extensions
//    3. IntoResponse — inserts T into response.extensions
//
//===----------------------------------------------------------------------===//

import Foundation
import HTTP
import StarlightTower

/// Extractor and layer for sharing state via request extensions.
///
/// Direct port of `axum::Extension<T>`.
///
/// # As extractor
///
/// ```swift
/// struct Database: Hashable, Sendable { /* ... */ }
///
/// let handler = HandlerService1(state: AnySendable()) { (_: Extension<Database>, _) in
///     // use $0.value
///     return .plain("ok")
/// }
/// ```
///
/// # As layer
///
/// ```swift
/// let app = Router(state: NoState())
///     .get("/", handler)
///     .layer(Extension.layer(Database()))
/// ```
///
/// If the extension is missing, the extractor rejects with 500
/// Internal Server Error — same as axum.
public struct Extension<T: Hashable & Sendable>: Sendable {
    public let value: T

    @inlinable public init(_ value: T) { self.value = value }

    /// Create a Layer that inserts `value` into every request's
    /// extensions. Direct port of `Extension<T> as tower::Layer`.
    public static func layer(_ value: T) -> Layer<HTTP.Request<Body>, HTTP.Response<Body>> {
        let v = value
        return Layer { inner in
            BoxService { request in
                var req = request
                req.extensions.insert(v)
                return try await inner.call(req)
            }
        }
    }
}

// MARK: - Extractor (FromRequestParts)

extension Extension: FromRequestParts {
    public typealias State = AnySendable

    public static func fromRequestParts(
        _ parts: inout RequestParts<Body>,
        state: borrowing AnySendable
    ) async throws -> Extension<T> {
        guard let value = parts.extensions.get(T.self) else {
            throw ExtractionRejection(
                "Extension of type `\(T.self)` not found. Perhaps you forgot to add a layer? See `Extension.layer(_:).",
                status: .internalServerError
            )
        }
        return Extension(value)
    }
}

// MARK: - IntoResponse

extension Extension: IntoResponse {
    public func intoResponse() -> HTTP.Response<Body> {
        // Insert value into response extensions — matches axum's
        // IntoResponse impl which puts T into res.extensions_mut().
        var headers = HeaderMap()
        headers.insert(.contentLength, "0")
        var response = HTTP.Response<Body>(status: .ok, headers: headers, body: .empty)
        response.extensions.insert(value)
        return response
    }
}
