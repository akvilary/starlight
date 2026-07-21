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
import StarlightHTTP
import StarlightTower

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
        StarlightHTTP.Request<Body>,
        Next
    ) async throws -> StarlightHTTP.Response<Body>

    @inlinable
    public init(_ run: @Sendable @escaping (
        StarlightHTTP.Request<Body>,
        Next
    ) async throws -> StarlightHTTP.Response<Body>) {
        self.run = run
    }
}

/// The "call the rest of the chain" handle passed to a `from_fn`
/// closure. axum calls this `Next`; it is the inner service wrapped
/// in a callable.
public struct Next: Sendable {
    @usableFromInline internal let inner: BoxService<StarlightHTTP.Request<Body>, StarlightHTTP.Response<Body>>

    @inlinable
    public init(_ inner: BoxService<StarlightHTTP.Request<Body>, StarlightHTTP.Response<Body>>) {
        self.inner = inner
    }

    @inlinable
    public func run(_ request: consuming StarlightHTTP.Request<Body>) async throws -> StarlightHTTP.Response<Body> {
        try await inner.call(request)
    }
}

/// Convenience — the axum `axum::middleware::from_fn` function.
/// Returns a `Layer` that, when applied to a service, runs the
/// supplied closure around every call.
public func from_fn(
    _ run: @Sendable @escaping (
        StarlightHTTP.Request<Body>,
        Next
    ) async throws -> StarlightHTTP.Response<Body>
) -> Layer<StarlightHTTP.Request<Body>, StarlightHTTP.Response<Body>> {
    Layer { inner in
        // Capture the FromFn by value so the closure is self-contained.
        let middleware = FromFn(run)
        return BoxService { request in
            try await middleware.run(request, Next(inner))
        }
    }
}
