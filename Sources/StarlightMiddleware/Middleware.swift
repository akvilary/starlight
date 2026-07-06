//===----------------------------------------------------------------------===//
//
//  Middleware.swift
//  StarlightMiddleware
//
//  Phase 0 placeholder — the real generic, monomorphized middleware protocol
//  (Tower/Rust-style, with `associatedtype` so the entire chain specializes
//  to a single `async` function with no per-request boxing) lands in Phase 4.
//
//===----------------------------------------------------------------------===//

import StarlightCore
import StarlightHTTP

/// A middleware sits between the server and the next handler in the chain.
///
/// Phase 0 placeholder. The Phase 4 design will use `associatedtype` so a chain
/// `Auth<Log<Router>>` compiles down to one concrete `async` function — no
/// existential boxing, no vtable dispatch, exactly mirroring Rust's Tower
/// `Service` trait.
public protocol Middleware {
    associatedtype Request
    associatedtype Response

    func handle(
        _ request: Request,
        next: borrowing MiddlewareNext<Self>
    ) async -> Response
}

/// Pointer to the next link in a middleware chain. `~Copyable` to enforce
/// exactly-once continuation semantics at compile time (a middleware either
/// calls `next` or returns a response — never both, never neither).
public struct MiddlewareNext<Parent: Middleware>: ~Copyable {
    public typealias Handler = @Sendable (Parent.Request) async -> Parent.Response

    @usableFromInline let handler: Handler

    @inlinable
    public init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    @inlinable
    public consuming func callAsFunction(_ request: Parent.Request) async -> Parent.Response {
        let handler = self.handler
        return await handler(request)
    }
}
