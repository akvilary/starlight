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
/// axum analogue:
///
/// ```swift
/// installShutdownSignalHandlers()
/// try await serve(
///     router,
///     on: "0.0.0.0", port: 8080,
///     onShutdown: { await waitForShutdownSignal() }
/// )
/// ```
public func serve<S: HTTPService>(
    _ service: S,
    on host: String = "0.0.0.0",
    port: Int = 8080,
    loopCount: Int = ProcessInfo.processInfo.activeProcessorCount,
    drainTimeout: Duration = .seconds(30),
    onShutdown: @escaping @Sendable () async -> Void = {
        await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
    }
) async throws {
    try await StarlightServer.serve(
        host: host, port: port,
        service: service,
        loopCount: loopCount,
        drainTimeout: drainTimeout,
        onShutdown: onShutdown
    )
}
