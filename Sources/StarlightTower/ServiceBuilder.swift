//===----------------------------------------------------------------------===//
//
//  ServiceBuilder.swift
//  StarlightTower
//
//  `ServiceBuilder` — direct port of `tower::ServiceBuilder`.
//
//  A fluent builder for layering services:
//
//      let layered = ServiceBuilder()
//          .layer(TimeoutLayer(duration: .seconds(30)))
//          .layer(TraceLayer())
//          .service(myHandler)
//
//  Each `.layer(...)` call captures the layer for later application.
//  `.service(inner)` folds the layers over `inner`, producing a
//  single `Service` that runs outermost-first on every request.
//
//===----------------------------------------------------------------------===//

import Foundation

/// Fluent layer pipeline builder.
///
/// Layers are captured in registration order; `.service(_:)`
/// applies them outermost-first (i.e. the first layer added wraps
/// everything else, matching `tower::ServiceBuilder`).
public struct ServiceBuilder<Request: Sendable, Response: Sendable>: Sendable {
    @usableFromInline
    internal var layers: [Layer<Request, Response>] = []

    @inlinable public init() {}

    /// Append a layer to the pipeline.
    @inlinable
    public func layer(_ layer: Layer<Request, Response>) -> ServiceBuilder<Request, Response> {
        var copy = self
        copy.layers.append(layer)
        return copy
    }

    /// Fold the captured layers over `inner`, producing the
    /// final wrapped service.
    ///
    /// Layers are applied outermost-first: the first layer added
    /// is the outermost wrap, the last layer added is the innermost.
    @inlinable
    public func service<S: Service>(_ inner: S) -> BoxService<Request, Response>
    where S.Request == Request, S.Response == Response {
        var current = BoxService<Request, Response>(inner)
        for layer in layers.reversed() {
            current = layer.layer(current)
        }
        return current
    }
}
