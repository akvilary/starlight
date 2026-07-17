//===----------------------------------------------------------------------===//
//
//  Server.swift
//  StarlightServer
//
//  Platform dispatch:
//
//    #if os(Linux) && $Lifetimes
//        try IORing → catch → NIO fallback
//    #endif
//    NIO backend (always available — primary on macOS, fallback on Linux)
//
//  Both paths share the same public API (StarlightServer.start/shutdown)
//  and the same HTTP layer (HTTP1Codec, Router, RequestContext, etc.).
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
#endif

// MARK: - Shared types

/// Connection counters for stats, padded to avoid false sharing.
public final class ServerStats: @unchecked Sendable {
    public let connectionsAccepted = PaddedAtomicInt64()
    public let bytesReceived = PaddedAtomicInt64()
    public let bytesSent = PaddedAtomicInt64()
    public let cqOverflowEvents = PaddedAtomicInt64()
    @inlinable public init() {}
}

/// The server mode — TCP echo (benchmark baseline) or HTTP/1.1.
public enum Mode: Sendable {
    case tcpEcho
    case http
}

// MARK: - io_uring backend (Linux + Lifetimes only)

#if os(Linux) && compiler(>=6.2) && $Lifetimes

import SystemPackage
import CLinuxExt

/// Check if SystemPackage.IORing is available at runtime.
/// Creates a throwaway ring — if kernel/seccomp blocks io_uring, returns false.
private func ioUringAvailable() -> Bool {
    do {
        _ = try IORing(queueDepth: 1, flags: [.singleSubmissionThread])
        return true
    } catch {
        return false
    }
}

#endif

// MARK: - StarlightServer (unified, all platforms)

public final class StarlightServer: @unchecked Sendable {
    public let stats = ServerStats()
    public let loopCount: Int

    /// Backend selected at start time. Surfaced for diagnostics
    /// (`backendName` in the benchmark banner).
    public private(set) var backend: Backend = .nio

    /// The I/O backend actually driving this server.
    public enum Backend: String, Sendable {
        case epoll     // StarlightPoll — default on Linux
        case ioUring   // StarlightIORing — opt-in (kernel ≥5.7)
        case nio       // NIOAsyncChannel — macOS / fallback
    }

    // epoll state (Linux only) — primary backend.
    #if os(Linux)
    private var epollLoops: [EpollExecutorLoop] = []
    private var epollShutdownContinuation: CheckedContinuation<Void, Never>?
    private var usingEpoll = false
    #endif

    // io_uring state (Linux only) — opt-in alternative.
    #if os(Linux) && compiler(>=6.2) && $Lifetimes
    private var ioRingLoops: [IORingExecutorLoop] = []
    private var shutdownContinuation: CheckedContinuation<Void, Never>?
    private var usingIORing = false
    #endif

    // NIO state (all platforms — primary on macOS, fallback on Linux)
    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var nioListeners: [NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never>] = []

    public init(loopCount: Int = System.coreCount) {
        self.loopCount = loopCount
    }

    // MARK: - Start / Shutdown

    /// Selects which Linux backend to use.
    public enum LinuxBackendPreference: Sendable {
        /// Default: epoll. Falls back to NIO if epoll is unavailable
        /// (essentially never on a Linux ≥2.6).
        case epoll
        /// Opt-in: io_uring. Falls back to epoll, then NIO.
        case ioUring
    }

    public func start(
        host: String,
        port: Int,
        mode: Mode = .http,
        httpHandler: HTTPHandler? = nil,
        router: Router? = nil,
        linuxBackend: LinuxBackendPreference = .epoll
    ) async throws {
        precondition(mode != .http || httpHandler != nil || router != nil,
                     "HTTP mode requires an httpHandler closure or a Router")

        // The Router is already an immutable, middleware-composed
        // snapshot produced by RouterBuilder.build() — no runtime
        // freeze step needed.

        #if os(Linux) && compiler(>=6.2) && $Lifetimes
        // Explicit io_uring preference — try io_uring first, then fall
        // through to epoll, then NIO.
        if linuxBackend == .ioUring, ioUringAvailable() {
            do {
                try await startWithIORing(host: host, port: port, mode: mode,
                                          httpHandler: httpHandler, router: router)
                backend = .ioUring
                return
            } catch {
                // Fall through to epoll.
            }
        }
        #endif

        #if os(Linux)
        // epoll — the default Linux backend. Production-proven (mio/
        // tokio use the same primitive), works in every container and
        // kernel version, no seccomp / capability gotchas.
        do {
            try await startWithEpoll(host: host, port: port, mode: mode,
                                     httpHandler: httpHandler, router: router)
            backend = .epoll
            return
        } catch {
            // Fall through to NIO.
        }
        #endif

        // NIO backend (primary on macOS, last-resort fallback on Linux).
        try await startWithNIO(host: host, port: port, mode: mode,
                               httpHandler: httpHandler, router: router)
        backend = .nio
    }

    public func shutdown() {
        #if os(Linux)
        if usingEpoll {
            for loop in epollLoops {
                loop.shutdown()
            }
            epollLoops.removeAll()
            epollShutdownContinuation?.resume()
            epollShutdownContinuation = nil
            usingEpoll = false
            return
        }
        #endif

        #if os(Linux) && compiler(>=6.2) && $Lifetimes
        if usingIORing {
            for loop in ioRingLoops {
                loop.shutdown()
            }
            ioRingLoops.removeAll()
            shutdownContinuation?.resume()
            shutdownContinuation = nil
            usingIORing = false
            return
        }
        #endif

        // NIO shutdown — close listeners and shut down the event loop
        // group. syncShutdownGracefully force-closes all connection
        // channels, which lets the discarding task group in startWithNIO
        // return. Must NOT be called from an event loop thread.
        for listener in nioListeners {
            listener.channel.close(promise: nil)
        }
        nioListeners.removeAll()

        if let elg = self.eventLoopGroup {
            try? elg.syncShutdownGracefully()
            self.eventLoopGroup = nil
        }
    }

    deinit {
        // Safety net: if shutdown() wasn't called explicitly, clean up
        // to prevent fd and thread leaks. shutdown() is idempotent —
        // safe to call twice. At this point start() has either returned
        // (fields already cleared) or was never called (fields empty).
        shutdown()
    }
}

// MARK: - epoll backend (Linux — default)

#if os(Linux)

extension StarlightServer {
    private func startWithEpoll(
        host: String, port: Int, mode: Mode,
        httpHandler: HTTPHandler?, router: Router?
    ) async throws {
        precondition(self.epollLoops.isEmpty, "StarlightServer already started")

        var created: [EpollExecutorLoop] = []
        do {
            for cpuIndex in 0..<loopCount {
                let loop = try EpollExecutorLoop(
                    host: host, port: port, mode: mode,
                    handler: httpHandler, router: router,
                    stats: self.stats, cpuIndex: CInt(cpuIndex)
                )
                try loop.setup()
                created.append(loop)

                let cpu = CInt(cpuIndex)
                Thread.detachNewThread { [loop] in
                    sl_pin_to_cpu(cpu)
                    do { try loop.run() }
                    catch { /* log */ }
                }
            }
        } catch {
            // Cleanup partial creation — fall through to NIO.
            for loop in created { loop.shutdown() }
            throw error
        }

        epollLoops = created
        usingEpoll = true

        // Suspend until shutdown() is called.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.epollShutdownContinuation = continuation
        }
    }
}

#endif

// MARK: - io_uring backend

#if os(Linux) && compiler(>=6.2) && $Lifetimes

extension StarlightServer {
    private func startWithIORing(
        host: String, port: Int, mode: Mode,
        httpHandler: HTTPHandler?, router: Router?
    ) async throws {
        precondition(self.ioRingLoops.isEmpty, "StarlightServer already started")

        var created: [IORingExecutorLoop] = []
        do {
            for cpuIndex in 0..<loopCount {
                let loop = IORingExecutorLoop(
                    host: host, port: port, mode: mode,
                    handler: httpHandler, router: router,
                    stats: self.stats, cpuIndex: CInt(cpuIndex)
                )
                try loop.setup()
                created.append(loop)

                let cpu = CInt(cpuIndex)
                Thread.detachNewThread { [loop] in
                    sl_pin_to_cpu(cpu)
                    do { try loop.run() }
                    catch { /* log */ }
                }
            }
        } catch {
            // Cleanup partial creation — fall through to NIO.
            for loop in created { loop.shutdown() }
            throw error
        }

        ioRingLoops = created
        usingIORing = true

        // Suspend until shutdown() is called.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.shutdownContinuation = continuation
        }
    }
}

#endif

// MARK: - NIO backend (all platforms)

extension StarlightServer {
    private func startWithNIO(
        host: String, port: Int, mode: Mode,
        httpHandler: HTTPHandler?, router: Router?
    ) async throws {
        precondition(self.nioListeners.isEmpty, "StarlightServer already started")

        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: loopCount)
        self.eventLoopGroup = eventLoopGroup

        for eventLoop in eventLoopGroup.makeIterator() {
            let listener = try await ServerBootstrap(group: eventLoop)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .serverChannelOption(ChannelOptions.socketOption(Self.soReusePort), value: 1)
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
            nioListeners.append(listener)
        }

        try await withThrowingDiscardingTaskGroup { listenerGroup in
            for listener in self.nioListeners {
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

    /// Cross-platform `SO_REUSEPORT` socket option value.
    static var soReusePort: NIOBSDSocket.Option {
        #if canImport(Glibc)
        return NIOBSDSocket.Option(rawValue: Glibc.SO_REUSEPORT)
        #elseif canImport(Darwin)
        return NIOBSDSocket.Option(rawValue: Darwin.SO_REUSEPORT)
        #else
        #error("SO_REUSEPORT not available on this platform")
        #endif
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
