//===----------------------------------------------------------------------===//
//
//  App.swift
//  Starlight
//
//  Public umbrella entry point. Re-exports the submodules and provides the
//  convenience `StarlightApp` builder API. The real result-builder DSL
//  (Hummingbird/Vapor-style) lands in Phase 4.
//
//===----------------------------------------------------------------------===//

import NIOCore
import NIOPosix
import StarlightCore
import StarlightHTTP
import StarlightRouting
import StarlightMiddleware
import StarlightServer

@_exported import StarlightCore
@_exported import StarlightHTTP
@_exported import StarlightRouting
@_exported import StarlightMiddleware
@_exported import StarlightServer

/// A configured but not-yet-started Starlight server.
///
/// `start()` and `wait()` are async — they are invoked once at process
/// startup and shutdown, never in any request hot path. Everything *inside*
/// a connection — request parsing, handler invocation, response writing —
/// runs concurrently on the event loop that owns the connection, under
/// Swift Concurrency via `EventLoopExecutor` +
/// `withTaskExecutorPreference`.
public final class StarlightApp: @unchecked Sendable {
    public let server: StarlightServer

    @inlinable
    public init(loopCount: Int = System.coreCount) {
        self.server = StarlightServer(loopCount: loopCount)
    }

    /// Bind on `(host, port)` and begin accepting connections. Returns once
    /// every per-loop listener is bound; call `wait()` afterwards to keep
    /// the process alive while event loops process connections.
    @inlinable
    public func start(host: String = "0.0.0.0", port: Int = 8080) async throws {
        try await self.server.start(host: host, port: port)
    }

    /// Suspend the calling task until the server shuts down. Use this from
    /// async `main` to keep the process alive while connections are handled
    /// concurrently on the event loops.
    @inlinable
    public func wait() async throws {
        try await self.server.wait()
    }

    /// Convenience: `start()` + `wait()`. Async — meant to be the last
    /// line of an async `@main` `static func main() async throws`.
    @inlinable
    public func run(host: String = "0.0.0.0", port: Int = 8080) async throws {
        try await self.start(host: host, port: port)
        try await self.wait()
    }
}
