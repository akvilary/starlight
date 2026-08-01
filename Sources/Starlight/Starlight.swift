//===----------------------------------------------------------------------===//
//
//  Starlight.swift
//  Starlight
//
//  Public umbrella. Re-exports every submodule and provides the
//  top-level `serve` convenience. The `axum` crate analogue.
//
//===----------------------------------------------------------------------===//

import Foundation

@_exported import StarlightCore
@_exported import StarlightExtractors
@_exported import HTTP
@_exported import HTTPLens
@_exported import Pulsar
@_exported import StarlightRouting
@_exported import StarlightServer
@_exported import HTTPPrism

#if canImport(Glibc)
import CLinuxExt
#endif

// Convenience top-level helpers — equivalent to axum's `axum::serve`
// shortcut. Most users will call `Router.serve(...)` directly.

/// Bind N worker actors to `(host, port)` and serve `router`.
///
/// With no `onShutdown` supplied, the server installs SIGINT/SIGTERM
/// handlers and blocks until either signal arrives — matching axum's
/// default behaviour. Pass a custom closure to drive shutdown yourself
/// (e.g. wait on a condition, a health-check flip, …).
///
/// axum analogue:
///
/// ```swift
/// try await serve(router, on: "0.0.0.0", port: 8080)
/// // Ctrl-C / kill -TERM triggers a graceful drain.
/// ```
///
/// `onShutdown` is forwarded to `StarlightServer.serve`. Passing `nil`
/// (the default) deliberately *omits* the argument so the downstream
/// default is used — a single source of truth for the shutdown policy.
public func serve<S: HTTPService>(
    _ service: S,
    on host: String = "0.0.0.0",
    port: Int = 8080,
    loopCount: Int = ProcessInfo.processInfo.activeProcessorCount,
    drainTimeout: Duration = .seconds(30),
    onShutdown: (@Sendable () async -> Void)? = nil
) async throws {
    if let onShutdown {
        try await StarlightServer.serve(
            host: host, port: port,
            service: service,
            loopCount: loopCount,
            drainTimeout: drainTimeout,
            onShutdown: onShutdown
        )
    } else {
        try await StarlightServer.serve(
            host: host, port: port,
            service: service,
            loopCount: loopCount,
            drainTimeout: drainTimeout
        )
    }
}
