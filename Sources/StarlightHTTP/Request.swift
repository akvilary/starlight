//===----------------------------------------------------------------------===//
//
//  Request.swift
//  StarlightHTTP
//
//  HTTP request — direct port of `http::Request<B>`.
//
//===----------------------------------------------------------------------===//

import Foundation

/// HTTP request, parameterised over the body type.
///
/// axum/hyper's `Request<B>` is generic over body so that the codec
/// can stream chunks (`Request<StreamBody>`) while the framework
/// exposes a fixed-buffer body (`Request<Body>`). We mirror that
/// here: handlers see `Request<Body>`, the codec internally may use
/// a streaming body type.
public struct Request<B: Sendable>: Sendable {
    public var method: Method
    public var uri: Uri
    public var version: Version
    public var headers: HeaderMap
    public var body: B
    /// Extension map — axum's `Request::extensions_mut` analogue.
    /// Used to thread per-request state (matched route id, client
    /// IP, etc.) between middleware and handlers without growing
    /// `Request` itself.
    public var extensions: Extensions

    @inlinable
    public init(
        method: Method = .GET,
        uri: Uri = Uri("/"),
        version: Version = .http11,
        headers: HeaderMap = HeaderMap(),
        body: B,
        extensions: Extensions = Extensions()
    ) {
        self.method = method
        self.uri = uri
        self.version = version
        self.headers = headers
        self.body = body
        self.extensions = extensions
    }
}

/// Concrete alias — what handlers see.
public typealias IncomingRequest = Request<Body>

extension Request where B == Body {
    /// Convenience initialiser with an empty body.
    @inlinable
    public init(
        method: Method = .GET,
        uri: Uri = Uri("/"),
        version: Version = .http11,
        headers: HeaderMap = HeaderMap()
    ) {
        self.init(method: method, uri: uri, version: version,
                  headers: headers, body: Body())
    }
}

/// Type-erased extension map.
///
/// Mirrors `http::Extensions`. Stores values keyed by type —
/// each type may have at most one value. Common uses in axum:
/// matched `RouteId`, captured `MatchedPath`, custom middleware
/// state (correlation IDs, auth principal, etc.).
public struct Extensions: @unchecked Sendable {
    @usableFromInline
    internal struct Box: @unchecked Sendable {
        @usableFromInline internal let value: AnyHashable

        @inlinable internal init(value: AnyHashable) { self.value = value }
    }

    @usableFromInline
    internal var storage: [ObjectIdentifier: Box] = [:]

    @inlinable public init() {}

    /// Insert `value` for its dynamic type, replacing any prior.
    @inlinable
    public mutating func insert<T: Hashable & Sendable>(_ value: T) {
        storage[ObjectIdentifier(T.self)] = Box(value: AnyHashable(value))
    }

    /// Get the value for type `T`, if any.
    @inlinable
    public func get<T: Hashable & Sendable>(_ type: T.Type = T.self) -> T? {
        storage[ObjectIdentifier(type)]?.value.base as? T
    }

    /// Remove the value for type `T`.
    @discardableResult
    @inlinable
    public mutating func remove<T: Hashable & Sendable>(_ type: T.Type = T.self) -> T? {
        if let removed = storage.removeValue(forKey: ObjectIdentifier(type)) {
            return removed.value.base as? T
        }
        return nil
    }
}
