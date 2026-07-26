//===----------------------------------------------------------------------===//
//
//  from_fn.swift
//  StarlightMiddleware
//
//  Direct port of `axum::middleware::from_fn`.
//
//  Wraps an async closure `(request, next) -> response` into a
//  `Layer` that, when applied to a service, runs the closure
//  around every call.
//
//===----------------------------------------------------------------------===//

import Foundation
import StarlightCore
import HTTP
import Pylon

/// The function shape `from_fn` accepts.
///
/// Equivalent to axum's:
///
/// ```rust
/// F: FnMut(Request, Next) -> Pin<Box<dyn Future<Output = Response> + Send>>
///     + Clone + Send + 'static
/// ```
public struct FromFn: Sendable {
    public let run: @Sendable (
        Request,
        Next
    ) async throws -> Response

    @inlinable
    public init(_ run: @Sendable @escaping (
        Request,
        Next
    ) async throws -> Response) {
        self.run = run
    }
}

/// The "call the rest of the chain" handle passed to a `from_fn`
/// closure. axum calls this `Next`; it is the inner service wrapped
/// in a callable.
public struct Next: Sendable {
    @usableFromInline internal let inner: BoxService<Request, Response>

    @inlinable
    public init(_ inner: BoxService<Request, Response>) {
        self.inner = inner
    }

    @inlinable
    public func run(_ request: consuming Request) async throws -> Response {
        try await inner.call(request)
    }
}

/// Convenience — the axum `axum::middleware::from_fn` function.
/// Returns a `Layer` that, when applied to a service, runs the
/// supplied closure around every call.
public func from_fn(
    _ run: @Sendable @escaping (
        Request,
        Next
    ) async throws -> Response
) -> Layer<Request, Response> {
    Layer { inner in
        // Capture the FromFn by value so the closure is self-contained.
        let middleware = FromFn(run)
        return BoxService { request in
            try await middleware.run(request, Next(inner))
        }
    }
}
