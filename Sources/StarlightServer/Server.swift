//===----------------------------------------------------------------------===//
//
//  Server.swift
//  StarlightServer
//
//  Platform dispatch:
//
//    #if os(Linux)  → io_uring backend (IOUringLoop, raw syscalls)
//    #else           → NIO backend (NIOAsyncChannel, existing code)
//
//  Both paths share the same public API (StarlightServer.start/shutdown)
//  and the same HTTP layer (HTTP1Codec, Router, RequestContext, etc.).
//
//===----------------------------------------------------------------------===//

import Foundation
import NIOCore
import StarlightCore
import StarlightHTTP
import StarlightRouting

#if canImport(Glibc)
import Glibc
#endif

// MARK: - Shared types

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

// MARK: - Linux: io_uring backend

#if os(Linux)

import CStarlightLinux

public final class StarlightServer: @unchecked Sendable {
    public let stats = ServerStats()
    public let loopCount: Int

    private var ioUringLoops: [IOUringLoop] = []
    private var shutdownContinuation: CheckedContinuation<Void, Never>?

    public init(loopCount: Int = System.coreCount) {
        self.loopCount = loopCount
    }

    // MARK: - Start / Shutdown

    public func start(
        host: String,
        port: Int,
        mode: Mode = .tcpEcho,
        httpHandler: HTTPHandler? = nil,
        router: Router? = nil
    ) async throws {
        precondition(mode != .http || httpHandler != nil || router != nil,
                     "HTTP mode requires an httpHandler closure or a Router")
        precondition(self.ioUringLoops.isEmpty, "StarlightServer already started")

        router?.freeze()

        // Create one IOUringLoop per CPU core with SO_REUSEPORT.
        for _ in 0..<loopCount {
            let loop = IOUringLoop(host: host, port: port,
                                   handler: httpHandler, router: router,
                                   stats: self.stats)
            try loop.setup()
            ioUringLoops.append(loop)

            Thread.detachNewThread { [loop] in
                do { try loop.run() }
                catch { /* log */ }
            }
        }

        // Suspend until shutdown() is called.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.shutdownContinuation = continuation
        }
    }

    public func shutdown() {
        for loop in ioUringLoops {
            loop.shutdown()
        }
        ioUringLoops.removeAll()
        shutdownContinuation?.resume()
    }
}

// MARK: - Non-Linux: NIO backend

#else

import NIOPosix

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

        router?.freeze()

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

    public func shutdown() {
        for listener in self.listeners {
            listener.channel.close(promise: nil)
        }
        self.listeners.removeAll()
    }

    // MARK: - Per-connection handling (NIO)

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
        } catch {}
    }

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
                                response.headerBuffer.readableBytes &+ bodyBuf.readableBytes))
                            try await outbound.write(contentsOf: [
                                response.headerBuffer, bodyBuf,
                            ])
                        } else {
                            _ = stats.bytesSent.add(Int64(response.headerBuffer.readableBytes))
                            try await outbound.write(response.headerBuffer)
                        }
                        if !response.keepAlive {
                            return
                        }
                    }
                }
            }
        } catch {}
    }
}

#endif // os(Linux)
