//===----------------------------------------------------------------------===//
//
//  App.swift
//  Starlight
//
//  Public umbrella entry point. Re-exports the submodules and provides
//  the convenience `StarlightApp` builder API.
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
/// `start()` is async and **blocks until shutdown** — the NIOAsyncChannel
/// accept loop runs inside a discarding task group. To shut down,
/// call `shutdown()` (typically from a signal handler).
public final class StarlightApp: @unchecked Sendable {
    public let server: StarlightServer

    @inlinable
    public init(loopCount: Int = System.coreCount) {
        self.server = StarlightServer(loopCount: loopCount)
    }

    /// Bind on `(host, port)` and run the accept loop until shutdown.
    /// This method blocks the calling task.
    @inlinable
    public func start(
        host: String = "0.0.0.0",
        port: Int = 8080,
        mode: Mode = .tcpEcho,
        httpHandler: HTTPHandler? = nil,
        router: Router? = nil
    ) async throws {
        try await self.server.start(
            host: host, port: port, mode: mode,
            httpHandler: httpHandler, router: router
        )
    }

    /// Shut down every listener. Causes `start()` to return.
    @inlinable
    public func shutdown() {
        self.server.shutdown()
    }
}
