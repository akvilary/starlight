//===----------------------------------------------------------------------===//
//
//  Layer.swift
//  StarlightTower
//
//  The `Layer` concept — pragmatic Swift port of `tower::Layer`.
//
//  Rust signature:
//
//      pub trait Layer<S> {
//          type Service;
//          fn layer(&self, inner: S) -> Self::Service;
//      }
//
//  Rust's `Layer` is generic over the inner service type because
//  tower is fully monomorphised — every layer in a chain has a
//  different concrete `S`. In Swift we accept type erasure at the
//  layer boundary: a `Layer` takes a `BoxService` and returns a
//  `BoxService`. This matches what `tower::ServiceBuilder` produces
//  in practice (everything ends up as `BoxCloneService<...>` in
//  axum's storage).
//
//  Concretely: a `Layer<R, R>` wraps `Service<R, R>` to add behaviour
//  — logging, auth, compression, retry, trace. Layers compose into
//  a pipeline at build time via `ServiceBuilder`, producing a single
//  wrapped service that performs all the wrapping on each call.
//
//===----------------------------------------------------------------------===//

import Foundation

/// Wraps an inner `Service` to add cross-cutting behaviour.
///
/// A `Layer` is a factory: it takes a service, returns a service.
/// The factory is applied once at composition time, never per
/// request.
///
/// `Layer` is a struct (closure-based) rather than a protocol —
/// Swift's associated-type dance on top of `Service` would force
/// every middleware through an `any` existential, and the
/// type-erasure cost would land on the hot path. With a struct
/// the closure is the layer; building one is one allocation.
public struct Layer<Request: Sendable, Response: Sendable>: Sendable {
    @usableFromInline
    internal let _layer:
        @Sendable (BoxService<Request, Response>) -> BoxService<Request, Response>

    @inlinable
    public init(
        _ layer: @Sendable @escaping (BoxService<Request, Response>) -> BoxService<Request, Response>
    ) {
        self._layer = layer
    }

    /// Wrap `inner` with this layer's behaviour.
    @inlinable
    public func layer(_ inner: BoxService<Request, Response>) -> BoxService<Request, Response> {
        _layer(inner)
    }

    /// Compose two layers — `outer.layer(inner)` followed by
    /// `self.layer(_:)`. Returns a new Layer that applies both.
    @inlinable
    public func followedBy(_ next: Layer<Request, Response>) -> Layer<Request, Response> {
        Layer { inner in self.layer(next.layer(inner)) }
    }
}
