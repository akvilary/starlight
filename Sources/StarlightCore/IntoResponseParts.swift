//===----------------------------------------------------------------------===//
//
//  IntoResponseParts.swift
//  StarlightCore
//
//  Port of `axum_core::response::IntoResponseParts`.
//
//  Types that contribute only parts of a response (status, headers)
//  without owning the body. Used to build responses via composition:
//
//    (StatusCode::CREATED, [("Location", "/users/42")], Json(user))
//
//  In axum, this is achieved via tuple `IntoResponse` impls generated
//  by a macro. Swift can't retroactively conform tuples to protocols,
//  so we provide:
//    1. `IntoResponseParts` protocol
//    2. Conformances for StatusCode, HeaderMap, Extension<T>
//    3. Convenience `Response.init(_ status:, headers:, body:)`
//
//===----------------------------------------------------------------------===//

import Foundation
import HTTP

/// A type that contributes parts of an HTTP response (status, headers,
/// extensions) without owning the body.
///
/// Direct port of `axum_core::response::IntoResponseParts`. Applied
/// to a `Response<Body>` via `apply(to:)`.
public protocol IntoResponseParts {
    /// Apply this part to the response. Modifies status, headers,
    /// or extensions in place.
    func apply(to response: inout Response<Body>)
}

// MARK: - Conformances

extension StatusCode: IntoResponseParts {
    public func apply(to response: inout Response<Body>) {
        response.status = self
    }
}

extension HeaderMap: IntoResponseParts {
    public func apply(to response: inout Response<Body>) {
        for (name, value) in entries {
            response.headers.append(name, value)
        }
    }
}

// MARK: - Convenience response builders
//
// These replace axum's tuple IntoResponse impls. Since Swift can't
// retroactively conform `(StatusCode, T)` tuples, we provide explicit
// convenience initializers.

extension Response where B == Body {
    /// Build a response from a status + an IntoResponse body.
    /// Matches axum's `(StatusCode, T: IntoResponse)` tuple.
    ///
    /// ```swift
    /// router.post("/users") { _ in
    ///     Response(.created, from: Json(newUser))
    /// }
    /// ```
    public init(_ status: StatusCode, from body: any IntoResponse) {
        var resp = body.intoResponse()
        resp.status = status
        self = resp
    }

    /// Build a response from a status + headers + an IntoResponse body.
    /// Matches axum's `(StatusCode, HeaderMap, T: IntoResponse)` tuple.
    public init(
        _ status: StatusCode,
        headers: HeaderMap,
        from body: any IntoResponse
    ) {
        var resp = body.intoResponse()
        resp.status = status
        for (name, value) in headers.entries {
            resp.headers.append(name, value)
        }
        self = resp
    }
}
