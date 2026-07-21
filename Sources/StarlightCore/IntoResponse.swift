//===----------------------------------------------------------------------===//
//
//  IntoResponse.swift
//  StarlightCore
//
//  Port of `axum_core::IntoResponse` — anything convertible to an
//  HTTP `Response`.
//
//===----------------------------------------------------------------------===//

import Foundation
import StarlightHTTP

/// Anything convertible to an HTTP response.
///
/// Mirrors `axum_core::response::IntoResponse`. Implementations:
///
/// • `Response<Body>` — identity.
/// • `&'static str` / `String` — wrapped as `text/plain` body.
/// • `StatusCode` — empty body with the given status.
/// • `Result<T, E>` where `T, E: IntoResponse`.
/// • `()` — 200 OK with empty body.
/// • `Json<T>` — application/json body.
///
/// Anything a handler returns must conform to `IntoResponse`. The
/// conformance is the bridge between handler return values and the
/// `Response<Body>` that the HTTP codec writes to the wire.
public protocol IntoResponse {
    func intoResponse() -> StarlightHTTP.Response<Body>
}

// ── Concrete conformences ──────────────────────────────────────────

extension StarlightHTTP.Response: IntoResponse where B == Body {
    @inlinable
    public func intoResponse() -> StarlightHTTP.Response<Body> { self }
}

extension StatusCode: IntoResponse {
    public func intoResponse() -> StarlightHTTP.Response<Body> {
        var headers = HeaderMap()
        headers.insert(.contentLength, "0")
        return StarlightHTTP.Response<Body>(status: self, headers: headers, body: Body())
    }
}

extension String: IntoResponse {
    public func intoResponse() -> StarlightHTTP.Response<Body> {
        .plain(self)
    }
}

extension StaticString: IntoResponse {
    public func intoResponse() -> StarlightHTTP.Response<Body> {
        let s = withUTF8Buffer { Array($0) }
        return .plain(String(decoding: s, as: UTF8.self))
    }
}

extension Substring: IntoResponse {
    public func intoResponse() -> StarlightHTTP.Response<Body> {
        .plain(String(self))
    }
}

extension Unit: IntoResponse {
    public func intoResponse() -> StarlightHTTP.Response<Body> {
        var headers = HeaderMap()
        headers.insert(.contentLength, "0")
        return StarlightHTTP.Response<Body>(status: .ok, headers: headers, body: Body())
    }
}

extension Result: IntoResponse where Success: IntoResponse, Failure: IntoResponse {
    public func intoResponse() -> StarlightHTTP.Response<Body> {
        switch self {
        case .success(let value): return value.intoResponse()
        case .failure(let error): return error.intoResponse()
        }
    }
}

/// Sentinel unit type — Swift's `()` cannot have a retroactive
/// conformance to a non-final protocol, so we expose this wrapper
/// for handlers that return no body.
public struct Unit: Sendable {
    @inlinable public init() {}
    public static let shared = Unit()
}
