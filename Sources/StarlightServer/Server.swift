//===----------------------------------------------------------------------===//
//
//  Server.swift
//  StarlightServer
//
//  Phase 0 entry point — minimal TCP echo server built on SwiftNIO with the
//  H2O-style thread-per-core accept model: one `ServerSocket` per event loop
//  with `SO_REUSEPORT`, so the *kernel* load-balances incoming connections
//  across loops (no acceptor thread, no user-space dispatch).
//
//  Every connection stays on the loop that accepted it for its entire
//  lifetime — no cross-loop migration, no shared mutable state in the hot
//  path. This is the substrate on top of which Phase 2 will bolt the HTTP/1
//  codec and the per-request arena.
//
//===----------------------------------------------------------------------===//

import Foundation
import NIOCore
import NIOPosix
import StarlightCore

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Cross-platform `SO_REUSEPORT` socket option value. SwiftNIO does not ship
/// a symbolic constant for it; both Linux (≥ 3.9) and macOS (≥ 10.11) define
/// it in `<sys/socket.h>`.
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

/// Connection counters for stats. Each counter is padded to its own pair of
/// cache lines so increments from different event loops never invalidate one
/// another's lines (the H2O false-sharing pattern).
public final class ServerStats: @unchecked Sendable {
    public let connectionsAccepted = PaddedAtomicInt64()
    public let bytesReceived = PaddedAtomicInt64()
    public let bytesSent = PaddedAtomicInt64()

    @inlinable public init() {}
}

/// A `StarlightServer` owns a `MultiThreadedEventLoopGroup` and one bound
/// listener `Channel` per event loop. The listener channels all share the
/// same `(host, port)` via `SO_REUSEPORT` and the kernel dispatches accepted
/// connections across them.
///
/// Phase 0 ships a TCP echo pipeline. Phase 2 will replace the echo handler
/// with the SIMD HTTP/1 codec and the `RequestContext` arena; the surrounding
/// per-loop listener structure will not change.
public final class StarlightServer: @unchecked Sendable {
    /// The event-loop group — one loop per CPU core by default. Each loop is
    /// the unambiguous owner of every connection it accepts.
    public let eventLoopGroup: MultiThreadedEventLoopGroup

    /// One bound listener `Channel` per event loop.
    public private(set) var listenerChannels: [any Channel] = []

    /// Aggregate stats across all loops.
    public let stats = ServerStats()

    /// Number of event loops (= OS threads) the server runs. Stored
    /// explicitly because `MultiThreadedEventLoopGroup` does not expose it.
    public let loopCount: Int

    /// Construct a server backed by a fresh `MultiThreadedEventLoopGroup`.
    ///
    /// - Parameter loopCount: number of event loops to run. Defaults to
    ///   `System.coreCount` — one loop per CPU core (H2O's "thread-per-core"
    ///   default).
    public init(loopCount: Int = System.coreCount) {
        self.loopCount = loopCount
        self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: loopCount)
    }

    /// Bind one listener per event loop on `(host, port)` with `SO_REUSEPORT`,
    /// so the kernel load-balances accepts. Returns when every listener is
    /// bound and accepting.
    ///
    /// This method is async so that `main` can stay async (canonical Swift
    /// Concurrency entry point). It is *not* in any request hot path — it
    /// runs once at process bootstrap. The synchronous `.wait()` form is
    /// used internally on the listener bind because there is nothing useful
    /// to overlap it with at startup.
    ///
    /// Everything *after* this point — connection handling, request parsing,
    /// response writing — runs concurrently on the event loops under Swift
    /// Concurrency via `EventLoopExecutor` and `withTaskExecutorPreference`.
    ///
    /// - Parameters:
    ///   - host: bind host (use `"0.0.0.0"` or `"::"` for all interfaces).
    ///   - port: bind port. Pass `0` to let the kernel assign a port; all
    ///     subsequent binds will reuse the same port via `SO_REUSEPORT`.
    public func start(host: String, port: Int) async throws {
        precondition(self.listenerChannels.isEmpty, "StarlightServer already started")
        try self.bindListeners(host: host, port: port)
    }

    /// Synchronous bind-and-listen helper. Factored out so that future
    /// variants (e.g. `NIOPosix.singleThreadedEventLoopGroup`) can swap in
    /// their own bind path without touching the public async surface.
    private func bindListeners(host: String, port: Int) throws {
        // ── A/B TEST: single-listener (multi-threaded group) vs per-loop ──
        // Toggle `usePerLoopListeners` to switch. Phase 0 ships per-loop
        // (H2O pattern); the single-listener branch is kept as a known-good
        // fallback for diagnosing accept-pipeline regressions.
        let usePerLoopListeners = true

        if !usePerLoopListeners {
            // Single-listener fallback: one ServerBootstrap on the whole
            // group, NIO itself round-robins child channels across loops.
            let stats = self.stats
            let channel = try ServerBootstrap(group: self.eventLoopGroup)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    let handler = EchoHandler(stats: stats)
                    return channel.pipeline.addHandler(handler)
                }
                .bind(host: host, port: port)
                .wait()
            self.listenerChannels.append(channel)
            return
        }

        // Bind one listener per event loop. Each ServerBootstrap is created
        // against a single-loop group (the event loop itself), which means
        // every accepted child channel is also owned by that same loop — no
        // cross-loop fan-out, no shared acceptor.
        for eventLoop in self.eventLoopGroup.makeIterator() {
            let stats = self.stats
            let channel = try ServerBootstrap(group: eventLoop)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .serverChannelOption(ChannelOptions.socketOption(SO_REUSEPORT), value: 1)
                .childChannelInitializer { channel in
                    // Phase 0: sync ChannelHandler pipeline (echo).
                    // Phase 2 will replace this with the SIMD HTTP/1 codec,
                    // and Phase 1 will introduce `RequestContext: ~Copyable`
                    // which the handler will populate. The pipeline stays
                    // sync; only user handler invocation will be async.
                    let handler = EchoHandler(stats: stats)
                    return channel.pipeline.addHandler(handler)
                }
                .bind(host: host, port: port)
                .wait()
            self.listenerChannels.append(channel)
        }
    }

    /// Block the calling task until every listener has closed. Use this from
    /// an async `main` to keep the process alive while event loops process
    /// connections concurrently.
    public func wait() async throws {
        // We deliberately do NOT use `for channel in listenerChannels { try await channel.closeFuture.get() }`
        // — that serializes the waits. Instead, race them all concurrently
        // and return as soon as the first one closes (which is typically
        // triggered by SIGINT-driven shutdown in StarlightApp).
        try await withThrowingTaskGroup(of: Void.self) { group in
            for channel in self.listenerChannels {
                group.addTask {
                    try await channel.closeFuture.get()
                }
            }
            // Wait for the first listener to close, then return. The other
            // tasks will be cancelled when the task group goes out of scope.
            try await group.next()
        }
    }

    /// Shut down every listener and the event-loop group. Blocks until the
    /// loops have drained.
    public func shutdown() async throws {
        for channel in self.listenerChannels {
            try await channel.close().get()
        }
        self.listenerChannels.removeAll()
        try await self.eventLoopGroup.shutdownGracefully()
    }
}

//===----------------------------------------------------------------------===//
// Echo handler — Phase 0 hot path
//===----------------------------------------------------------------------===//

/// TCP echo handler. Every byte received is written back on the same channel.
///
/// Phase 0's purpose: give us a number. wrk against this echo server tells us
/// the throughput ceiling of our per-loop `SO_REUSEPORT` acceptor model
/// before any HTTP machinery is added — that's the baseline against which
/// Phase 2's parser and Phase 3's `writev` response builder will be judged.
final class EchoHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let stats: ServerStats

    @inlinable init(stats: ServerStats) {
        self.stats = stats
    }

    func channelActive(context: ChannelHandlerContext) {
        _ = self.stats.connectionsAccepted.increment()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = self.unwrapInboundIn(data)
        let n = Int64(buffer.readableBytes)
        _ = self.stats.bytesReceived.add(n)
        // Echo: write back exactly what we received. The byte buffer's
        // reference-counted storage makes this a no-copy write until the
        // kernel pulls it out on flush.
        context.write(self.wrapOutboundOut(buffer), promise: nil)
        _ = self.stats.bytesSent.add(n)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // Phase 0: close on error, no logging (avoids any I/O on the hot path).
        context.close(promise: nil)
    }
}
