//===----------------------------------------------------------------------===//
//
//  Service.swift
//  StarlightTower
//
//  The `Service` protocol — direct port of `tower::Service`.
//
//  A `Service` consumes a `Request` and asynchronously produces a
//  `Response`. It is the central abstraction that axum/hyper/tower
//  are built around: every handler, every middleware, every router
//  is fundamentally a `Service<Request>`.
//
//  Rust signature:
//
//      pub trait Service<Request> {
//          type Response;
//          type Error;
//          type Future: Future<Output = Result<Self::Response, Self::Error>>;
//          fn poll_ready(&mut self, cx: &mut Context<'_>)
//              -> Poll<Result<(), Self::Error>>;
//          fn call(&mut self, req: Request) -> Self::Future;
//      }
//
//  Swift translation notes
//  -----------------------
//  • `poll_ready` is a Rust optimisation for reserving backpressure
//    capacity before `call`. Swift Concurrency models backpressure via
//    `async`; the equivalent is just awaiting the call itself. We
//    therefore collapse `poll_ready + call` into a single `async`
//    method, matching how axum uses tower in practice (every `Service`
//    is wrapped in `RouterService` / `into_service` that calls
//    `poll_ready`-then-`call` as a single future).
//
//  • `associatedtype Future: Future` collapses to `async throws -> …`
//    in the signature. The compiler synthesises the future machine.
//
//  • Swift has no trait objects (dyn Service); `BoxService<R, R>` below
//    provides the equivalent via closure-based type erasure, mirroring
//    tower's `Service` trait object via `BoxErrorService`.
//
//===----------------------------------------------------------------------===//

import Foundation

/// Asynchronous `Request -> Response` transformer — the central
/// abstraction of the framework.
///
/// Conforms-to-`Service` types include routers, middleware, route
/// handlers (via `HandlerService`), and the whole axum `Router<S>`
/// itself: `Router<S>` is `Service<Request, Response = Response>`.
///
/// The protocol is intentionally minimal: one `async throws` method.
/// Higher layers compose `Service`s into pipelines via `Layer`
/// (see Layer.swift).
public protocol Service: Sendable {
    /// Input type. Concrete `Service`s fix this to `Request` (the
    /// StarlightHTTP type) but the protocol is generic so it can
    /// model non-HTTP pipelines (e.g. tonic gRPC) identically to
    /// tower.
    associatedtype Request: Sendable

    /// Output type. For an HTTP service this is `Response`.
    associatedtype Response: Sendable

    /// Process the request, returning a response or throwing.
    ///
    /// `consuming` keeps ownership of the request in the caller's
    /// frame until the moment of dispatch; combined with the value
    /// semantics of `Request` (heap-backed only by its `Body`), this
    /// gives zero-copy hand-off to the service for the common case.
    ///
    /// For HTTP, throws is reserved for protocol-level errors
    /// (hyper's equivalent is `hyper::Error`); application errors
    /// should be returned as a 5xx `Response`, not thrown.
    func call(_ request: consuming Request) async throws -> Response
}
