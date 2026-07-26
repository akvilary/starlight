//===----------------------------------------------------------------------===//
//
//  Handler.swift
//  StarlightCore
//
//  Direct port of `axum_core::Handler`.
//
//  A `Handler` is a function that takes some extractors as positional
//  arguments and returns an `IntoResponse`. axum genericises this via
//  variadic tuples `Handler<(T0, T1, …, Tn), S, B>`; Swift 6.2 has
//  parameter packs but the ergonomics around extracting them positionally
//  into a closure call are still poor.
//
//  We use the same runtime trick axum uses for `from_fn` / `Router::route`:
//  a `Handler` is stored as a type-erased async closure
//  `(HTTP.Request, State) async throws -> HTTP.Response`, and
//  specific extractor arity combinations are wrapped by `HandlerService`
//  adapters (see HandlerService.swift). This is exactly how
//  `tower::Service::call` ends up dispatching in axum after all the
//  macros lower the variadic tuple.
//
//===----------------------------------------------------------------------===//

import Foundation
import HTTP
import Prism

/// The function-like thing a route handler is.
///
/// Concrete conformers are `HandlerService<T0, T1, …, S>` — one per
/// supported arity. Each is a thin struct that stores the user's
/// closure and conforms to `Service<HTTP.Request, Response = HTTP.Response>`,
/// running each extractor in turn and feeding the results to the
/// user's closure.
///
/// Application code rarely names `Handler` directly — it shows up in
/// `Router<S>.get(_:_:handler:)` etc. constraints.
public protocol Handler: Service, Sendable
where Self.Request == HTTP.Request,
      Self.Response == HTTP.Response {}

/// The "no state" state value. Used by routers that have no `S`.
@frozen
public struct NoState: Sendable {
    @inlinable public init() {}
}

/// Convenience alias for the response type every `Handler` returns.
public typealias HandlerResponse = HTTP.Response
