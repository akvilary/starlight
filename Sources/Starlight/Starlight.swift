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
@_exported import StarlightMiddleware
@_exported import StarlightPoll
@_exported import StarlightRouting
@_exported import StarlightServer
@_exported import StarlightTower

#if canImport(Glibc)
import CLinuxExt
#endif

// Convenience top-level helpers — equivalent to axum's `axum::serve`
// shortcut. Most users will call `Router.serve(...)` directly.

/// Bind a TCP listener and serve `router` on every accepted connection.
///
/// axum analogue:
///
/// ```swift
/// let router = Router(state: AppState())
///     .get("/") { _ in .plain("hello") }
///     .get("/users/:id") { (p: Path<User>) in ... }
/// try await serve(router, on: "0.0.0.0", port: 8080)
/// ```
public func serve<S: Service>(
    _ service: S,
    on host: String = "0.0.0.0",
    port: Int = 8080,
    loopCount: Int = ProcessInfo.processInfo.activeProcessorCount
) async throws where S.Request == Request<Body>,
                      S.Response == Response<Body> {
    let listener = try TcpListener.bind(host: host, port: port)
    try await StarlightServer.serve(
        listener: listener,
        service: service,
        loopCount: loopCount
    )
}
