//===----------------------------------------------------------------------===//
//
//  Server.swift
//  StarlightServer
//
//  NIOAsyncChannel-based server with the H2O-style thread-per-core accept
//  model: one listener per event loop with SO_REUSEPORT, kernel-balanced
//  accepts, and **one Task per connection** (not per request).
//
//  Phase 4.1a refactor: replaces the ChannelHandler pipeline with
//  NIOAsyncChannel's AsyncSequence API. This is the foundational step
//  for zero-cost async handlers (Phase 4.1b) — handlers will be
//  invoked inline in the connection Task via `await`, with no
//  Task-per-request allocation.
//
//  Every connection stays on the loop that accepted it for its entire
//  lifetime — no cross-loop migration, no shared mutable state in the
//  hot path.
//
//===----------------------------------------------------------------------===//

import Foundation
import NIOCore
import NIOPosix
import StarlightCore
import StarlightHTTP
import StarlightRouting

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Cross-platform `SO_REUSEPORT` socket option value.
@inlinable
var SO_REUSEPORT: NIOBSDSocket.Option {
    #if canImport(Glibc)
    return NIOBSDSocket.Option(rawValue: Glibc.SO_REUSEPORT)
    #elseif canImport(Darwin)
    return NIOBSDSocket.Option(rawValue: Darwin.SO_REUSEPORT)
    #else
    return NIOBSDSocket.Option(rawValue: 15)
    #endif
}

/// Connection counters for stats, padded to avoid false sharing.
public final class ServerStats: @unchecked Sendable {
    public let connectionsAccepted = PaddedAtomicInt64()
    public let bytesReceived = PaddedAtomicInt64()
    public let bytesSent = PaddedAtomicInt64()
    @inlinable public init() {}
}

/// The server mode — TCP echo (benchmark baseline) or HTTP/1.1.
public enum Mode: Sendable {
    case tcpEcho
    case http
}

/// A `StarlightServer` owns a `MultiThreadedEventLoopGroup` and one
/// bound listener per event loop via `NIOAsyncChannel`.
///
/// Each listener uses `SO_REUSEPORT` so the kernel load-balances
/// accepts across loops. Connections are handled by **one Task per
/// connection** (amortized through keep-alive requests), with the
/// handler invoked inline in the connection Task.
public final class StarlightServer: @unchecked Sendable {
    public let eventLoopGroup: MultiThreadedEventLoopGroup
    public let stats = ServerStats()
    public let loopCount: Int

    /// Bound listeners. Populated by `start()`, closed by `shutdown()`.
    private var listeners: [NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never>] = []

    public init(loopCount: Int = System.coreCount) {
        self.loopCount = loopCount
        self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: loopCount)
    }

    // MARK: - Start / Shutdown

    /// Bind one listener per event loop on `(host, port)` and run the
    /// accept loop until shutdown. This method blocks the calling task.
    public func start(
        host: String,
        port: Int,
        mode: Mode = .tcpEcho,
        httpHandler: HTTPHandler? = nil,
        router: Router? = nil
    ) async throws {
        precondition(mode != .http || httpHandler != nil || router != nil,
                     "HTTP mode requires an httpHandler closure or a Router")
        precondition(self.listeners.isEmpty, "StarlightServer already started")

        // Freeze the router before any connection is accepted.
        // This pre-composes middleware into each route's handler
        // exactly once, on the start() caller's thread — eliminating
        // the data race that occurred when multiple event loops
        // called freeze() concurrently from handle().
        router?.freeze()

        // Create per-loop listeners with SO_REUSEPORT.
        for eventLoop in self.eventLoopGroup.makeIterator() {
            let listener = try await ServerBootstrap(group: eventLoop)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .serverChannelOption(ChannelOptions.socketOption(SO_REUSEPORT), value: 1)
                .bind(host: host, port: port) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try NIOAsyncChannel(
                            wrappingChannelSynchronously: channel,
                            configuration: .init(
                                inboundType: ByteBuffer.self,
                                outboundType: ByteBuffer.self
                            )
                        )
                    }
                }
            self.listeners.append(listener)
        }

        // Run all listeners concurrently. Each listener owns its own
        // discarding task group for connections — this avoids the
        // "escaping closure captures inout parameter" error when
        // trying to use a single outer group for both listeners and
        // connections.
        try await withThrowingDiscardingTaskGroup { listenerGroup in
            for listener in self.listeners {
                let stats = self.stats
                let mode = mode
                let handler = httpHandler
                let router = router
                listenerGroup.addTask {
                    try await withThrowingDiscardingTaskGroup { connGroup in
                        try await listener.executeThenClose { inbound in
                            for try await connectionChannel in inbound {
                                _ = stats.connectionsAccepted.increment()
                                connGroup.addTask {
                                    await Self.handleConnection(
                                        channel: connectionChannel,
                                        mode: mode,
                                        stats: stats,
                                        handler: handler,
                                        router: router
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Close every listener. Causes `start()` to return.
    public func shutdown() {
        for listener in self.listeners {
            listener.channel.close(promise: nil)
        }
        self.listeners.removeAll()
    }

    // MARK: - Per-connection handling

    /// Dispatch a single accepted connection to the appropriate
    /// handler based on the server mode.
    private static func handleConnection(
        channel: NIOAsyncChannel<ByteBuffer, ByteBuffer>,
        mode: Mode,
        stats: ServerStats,
        handler: HTTPHandler?,
        router: Router?
    ) async {
        switch mode {
        case .tcpEcho:
            await handleEchoConnection(channel: channel, stats: stats)
        case .http:
            await handleHTTPConnection(channel: channel, stats: stats, handler: handler, router: router)
        }
    }

    /// TCP echo — bounce every received byte back. This is the
    /// benchmark baseline that isolates NIOAsyncChannel overhead from
    /// HTTP parsing.
    private static func handleEchoConnection(
        channel: NIOAsyncChannel<ByteBuffer, ByteBuffer>,
        stats: ServerStats
    ) async {
        do {
            try await channel.executeThenClose { (inbound, outbound) in
                for try await bytes in inbound {
                    let n = Int64(bytes.readableBytes)
                    _ = stats.bytesReceived.add(n)
                    _ = stats.bytesSent.add(n)
                    try await outbound.write(bytes)
                }
            }
        } catch {
            // Connection error — the channel is already closed by
            // executeThenClose.
        }
    }

    /// HTTP/1.1 connection handler. One `HTTP1Codec` instance per
    /// connection, reused across all keep-alive requests.
    private static func handleHTTPConnection(
        channel: NIOAsyncChannel<ByteBuffer, ByteBuffer>,
        stats: ServerStats,
        handler: HTTPHandler?,
        router: Router?
    ) async {
        let codec: HTTP1Codec
        if let router = router {
            codec = HTTP1Codec(router: router)
        } else if let handler = handler {
            codec = HTTP1Codec(handler: handler)
        } else {
            return
        }

        do {
            try await channel.executeThenClose { (inbound, outbound) in
                for try await bytes in inbound {
                    _ = stats.bytesReceived.add(Int64(bytes.readableBytes))
                    codec.feed(bytes)
                    while let response = await codec.tryParse() {
                        if let bodyBuf = response.bodyBuffer {
                            _ = stats.bytesSent.add(Int64(
                                response.buffer.readableBytes &+ bodyBuf.readableBytes))
                            try await outbound.write(contentsOf: [
                                response.buffer, bodyBuf,
                            ])
                        } else {
                            _ = stats.bytesSent.add(Int64(response.buffer.readableBytes))
                            try await outbound.write(response.buffer)
                        }
                        if !response.keepAlive {
                            return
                        }
                    }
                }
            }
        } catch {
            // Connection error — channel already closed.
        }
    }
}
