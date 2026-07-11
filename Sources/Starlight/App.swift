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
import StarlightCore
import StarlightHTTP
import StarlightRouting
import StarlightServer

@_exported import StarlightCore
@_exported import StarlightHTTP
@_exported import StarlightRouting
@_exported import StarlightServer

/// A configured but not-yet-started Starlight server.
///
/// `start()` is async and **blocks until shutdown**. On Linux the
/// io_uring accept loop runs inside a discarding task group; on macOS
/// NIOAsyncChannel is used. To shut down, call `shutdown()`.
public final class StarlightApp: Sendable {
    public let server: StarlightServer

    public init(loopCount: Int = System.coreCount) {
        self.server = StarlightServer(loopCount: loopCount)
    }

    /// Bind on `(host, port)` and run the accept loop until shutdown.
    /// This method blocks the calling task.
    public func start(
        host: String = "0.0.0.0",
        port: Int = 8080,
        mode: Mode = .http,
        httpHandler: HTTPHandler? = nil,
        router: Router? = nil
    ) async throws {
        try await self.server.start(
            host: host, port: port, mode: mode,
            httpHandler: httpHandler, router: router
        )
    }

    /// Shut down every listener. Causes `start()` to return.
    public func shutdown() {
        self.server.shutdown()
    }
}
