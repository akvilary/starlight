//===----------------------------------------------------------------------===//
//
//  BoxService.swift
//  StarlightTower
//
//  Type-erased `Service` — the Swift analogue of tower's
//  `BoxService` / dyn `Service<Request>` trait object.
//
//  Swift has no native trait objects: a protocol with `associatedtype`
//  cannot be used as an existential (`any Service`) without also
//  specifying the associated-type binding at every use site. axum
//  solves this in Rust with `BoxCloneService<Request, Response, Error>`
//  — a heap-allocated, cloneable, type-erased `Service`. We mirror
//  that with `BoxService<Request, Response>`.
//
//  Implementation: a single closure capturing the underlying service.
//  Closure-based erasure is the idiomatic Swift pattern (vs. vtable
//  generation via `any P` for protocols without associated types)
//  because:
//
//    1. It lets the wrapped service keep its own generics (the
//       `Request`/`Response` are bound only at the wrap site).
//    2. It is `@Sendable`-checkable — the closure captures a
//       `Sendable` service value, which the compiler verifies.
//    3. It inlines cleanly when wrapped services are concrete.
//
//===----------------------------------------------------------------------===//

import Foundation

/// A type-erased `Service`.
///
/// Wraps any `Service` whose `Request`/`Response` match, exposing
/// only the `call(_:)` surface. Stored as a single closure —
/// allocation is one box per wrap, paid at composition time, not
/// per request.
///
/// axum stores routes internally as
/// `HashMap<RouteId, BoxCloneService<Request, Response, Infallible>>`;
/// Starlight stores them as `HashMap<RouteId, BoxService<Request, Response>>`.
public struct BoxService<Request: Sendable, Response: Sendable>: Sendable {
    /// The erased call site. Captures the underlying service value.
    @usableFromInline
    internal let _call: @Sendable (Request) async throws -> Response

    /// Wrap a concrete `Service` in the type-erased box.
    @inlinable
    public init<S: Service>(_ service: S) where S.Request == Request, S.Response == Response {
        // Capture by value — `service` is moved into the closure.
        // For class-backed services this is one refcount increment;
        // for struct services this is one copy of the stored fields.
        self._call = { request in
            try await service.call(request)
        }
    }

    /// Construct directly from a closure — used by `Layer`s and
    /// middleware that build a service inline rather than wrapping
    /// an existing one.
    @inlinable
    public init(_ call: @escaping @Sendable (Request) async throws -> Response) {
        self._call = call
    }

    /// Dispatch the request.
    @inlinable
    public func call(_ request: consuming Request) async throws -> Response {
        // `consuming` is satisfied here by passing `request` to the
        // closure; the closure takes ownership and forwards to the
        // underlying service.
        try await _call(request)
    }
}

/// Helper to erase any `Service` to `BoxService<R, R>` with the
/// inferred type parameters. Mirrors tower's `ServiceExt::boxed`.
@inlinable
public func erase<S: Service>(_ service: S) -> BoxService<S.Request, S.Response> {
    BoxService(service)
}
