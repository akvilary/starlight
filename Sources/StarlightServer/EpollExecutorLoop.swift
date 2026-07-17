//===----------------------------------------------------------------------===//
//
//  EpollExecutorLoop.swift
//  StarlightServer
//
//  HTTP-specific event loop built on StarlightPoll.PollEventLoop
//  (the epoll-backed mio analog). Manages accept, connections, and
//  HTTP/echo protocol loops. Delegates generic async I/O to
//  PollEventLoop. Mirrors IORingExecutorLoop 1:1 — same public
//  surface, same connection/HTTP codec wiring, but uses readiness
//  notifications on epoll instead of io_uring submissions.
//
//  ─── Connection model (Tokio-style) ──────────────────────────────────
//
//  Each accepted connection spawns a Task via:
//
//      Task(executorPreference: eventLoop) { ... }
//
//  (SE-0431, `TaskExecutor` protocol). The Task runs on the loop's
//  thread, owns its state on its own frame (fd, read buffer, codec),
//  and tears down via `defer` on exit. No per-connection actor is
//  needed — the loop's executor pins the Task directly.
//
//===----------------------------------------------------------------------===//

#if os(Linux)

import Foundation
import CLinuxExt
import NIOCore
import StarlightCore
import StarlightPoll
import StarlightHTTP
import StarlightRouting

#if canImport(Glibc)
import Glibc
#endif

// MARK: - ConnectionState
//
// Immutable bag of per-connection state that needs to outlive the
// Task frame — specifically, the channelId is needed by the loop's
// `connections` table for shutdown cancellation. The fd is stored as
// the dict key. Everything else (codec, read buffer) is owned by the
// per-connection Task directly.

struct EpollConnectionState: Sendable {
    let channelId: UInt32
}

// MARK: - EpollExecutorLoop (HTTP-specific wrapper around PollEventLoop)

final class EpollExecutorLoop: @unchecked Sendable {

    let eventLoop: PollEventLoop
    private let host: String
    private let port: Int
    private let handler: HTTPHandler?
    private let router: Router?
    private let isEchoMode: Bool
    private let readBufferSize: Int = 4096
    private let maxConnectionsPerLoop: Int
    private let cpuIndex: CInt
    internal let loopStats: ServerStats

    private var listenerFd: CInt = -1
    /// channelId of the listener watch registered with `eventLoop`.
    /// Stored so `shutdown()` can call `cancelChannel` and break the
    /// retain cycle (the watch closure captures `self` weakly, but
    /// explicit cancellation is unconditional and releases the closure
    /// immediately).
    private var listenerWatchId: UInt32 = 0
    /// fd → channelId of every active connection. Used by shutdown's
    /// drainConnections() to cancel channels and close fds. Mutated
    /// only on the loop thread (handleAccept, closeConnection,
    /// drainConnections all run there).
    private var connections: [CInt: EpollConnectionState] = [:]
    private var connectionCount: Int = 0

    // MARK: Init

    init(host: String, port: Int, mode: Mode,
         handler: HTTPHandler?, router: Router?,
         stats: ServerStats, cpuIndex: CInt) throws {
        // PollEventLoop() can throw if epoll_create1 fails (extremely
        // rare — only on fd exhaustion or a kernel without epoll, which
        // every supported Linux has).
        self.eventLoop = try PollEventLoop(eventsCapacity: 4096)
        self.host = host
        self.port = port
        self.isEchoMode = (mode == .tcpEcho)
        self.handler = handler
        self.router = router
        self.loopStats = stats
        self.cpuIndex = cpuIndex
        // Each epoll fd can hold up to /proc/sys/fs/epoll/max_user_watches
        // entries. Default is ~8.5M on a 64-bit kernel with 1GB RAM, but
        // per-loop we cap at a safe ceiling well below the io_uring depth
        // because each entry corresponds to a live socket.
        self.maxConnectionsPerLoop = 8192 - 8
    }

    deinit {
        if listenerFd >= 0 { Glibc.close(listenerFd) }
    }

    // MARK: Setup

    func setup() throws {
        let lfd = linuxCreateListener(host: host, port: port)
        guard lfd >= 0 else {
            throw PollError(code: Int32(-lfd), function: "linuxCreateListener")
        }
        listenerFd = lfd
    }

    // MARK: Run (delegates to PollEventLoop)

    func run() throws {
        // Register the listening socket as a watch channel directly with
        // epoll for readability (level-triggered, persistent — NOT
        // oneshot). When the kernel reports pending connections, the
        // handler drains them with accept4 on the loop thread. This
        // eliminates the separate accept thread, its spinlock queue, and
        // the cross-thread wakeup per accept burst — matching the
        // mio/tokio idiom of registering the listener with the reactor.
        //
        // `[weak self]` + explicit `cancelChannel(listenerWatchId)` in
        // `shutdown()` breaks the retain cycle:
        //   EpollExecutorLoop ─strong→ eventLoop
        //   ─strong→ channels[id].watch closure ─strong→ EpollExecutorLoop
        // Without this the deinit never runs and listenerFd / readBuffers
        // leak for the lifetime of the process.
        listenerWatchId = try eventLoop.registerWatch(
            fd: listenerFd, interest: .readable
        ) { [weak self] ready in
            guard ready.isReadable else { return }
            self?.handleAccept()
        }

        try eventLoop.run()

        drainConnections()
    }

    func shutdown() {
        // Tear down the listener watch before stopping the loop —
        // releases the closure that captures `self` and breaks the
        // retain cycle unconditionally. Idempotent: safe to call
        // multiple times (cancelChannel on an unknown id is a no-op).
        if listenerWatchId != 0 {
            eventLoop.cancelChannel(listenerWatchId)
            listenerWatchId = 0
        }
        eventLoop.shutdown()
    }

    // MARK: Accept (runs inline on the loop thread via the watch handler)

    /// Drain the listening socket's accept queue. Called from the loop
    /// thread when the listener reports readable. Loops on non-blocking
    /// `accept4` until `EAGAIN`, satisfying the level-triggered "drain
    /// readiness" contract so the kernel does not re-fire the event until
    /// a new connection arrives. Each accepted fd is handed off to
    /// `setupNewConnection`, which spawns a connection-loop Task pinned
    /// to this loop's executor via `Task(executorPreference:)`.
    private func handleAccept() {
        while !eventLoop.isStopped {
            let fd = sl_accept4(listenerFd)
            if fd < 0 { break } // EAGAIN — queue drained.
            _ = linuxSetTcpNoDelay(fd)
            linuxSetKeepalive(fd)
            setupNewConnection(fd)
        }
    }

    private func setupNewConnection(_ fd: CInt) {
        guard connectionCount < maxConnectionsPerLoop else {
            Glibc.close(fd)
            return
        }
        _ = loopStats.connectionsAccepted.increment()
        connectionCount += 1

        let channelId = eventLoop.registerChannel()
        connections[fd] = EpollConnectionState(channelId: channelId)

        // Spawn a Task pinned directly to the loop via TaskExecutor
        // (SE-0431). No actor wrapper needed — `executorPreference`
        // enqueues the Task's first job onto the loop, and subsequent
        // continuations (after `await eventLoop.read/write`) resume on
        // the same loop thread. State is owned by the Task frame:
        // readBuffer allocated here, codec constructed here.
        //
        // Capture list is `[weak self]` so the loop can deinit if the
        // Task outlives it (defensive — shutdown() drains connections
        // explicitly).
        let isEchoMode = self.isEchoMode
        let readBufferSize = self.readBufferSize
        let router = self.router
        let handler = self.handler
        Task(executorPreference: eventLoop) { [weak self] in
            // Per-connection read buffer — owned by this Task,
            // deallocated on exit (echo / HTTP / error path alike).
            let readBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: readBufferSize)
            defer { readBuffer.deallocate() }

            if isEchoMode {
                await self?.echoLoop(fd: fd, channelId: channelId,
                                      readBuffer: readBuffer,
                                      readBufferSize: readBufferSize)
            } else {
                // Codec — constructed here, owned by this Task. Will
                // become `~Copyable struct` in Phase C; for now it's
                // still a class, but the ownership is unambiguous: no
                // other reference exists.
                var codec: HTTP1Codec
                if let router = router {
                    codec = HTTP1Codec(router: router)
                } else {
                    codec = HTTP1Codec(handler: handler!)
                }
                await self?.httpLoop(fd: fd, channelId: channelId,
                                     readBuffer: readBuffer,
                                     readBufferSize: readBufferSize,
                                     codec: &codec)
            }
        }
    }

    // MARK: Connection cleanup

    /// Idempotent: if the fd is still in the connections table, remove
    /// it, cancel its channel, and close the fd exactly once. If the fd
    /// is already gone (closed by drainConnections or by a prior
    /// closeConnection call), this is a no-op.
    //
    // The fd is closed ONLY when it was found in the table. A missing
    // entry means drainConnections() (or another closeConnection) has
    // already closed it — calling close(fd) again on a recycled fd
    // would be a use-after-free (the kernel may have handed that fd to
    // another thread's socket()/accept4()).
    func closeConnection(fd: CInt) {
        if let state = connections.removeValue(forKey: fd) {
            connectionCount -= 1
            eventLoop.cancelChannel(state.channelId)
            Glibc.close(fd)
        }
    }

    private func drainConnections() {
        for (_, state) in connections {
            eventLoop.cancelChannel(state.channelId)
            // fd is closed by the connection Task on its exit (via
            // closeConnection or by returning from the loop). Here we
            // only cancel the channel — the Task will observe the
            // cancelled read/write and exit.
        }
        connections.removeAll()
        connectionCount = 0
    }

    // MARK: Connection loops

    func echoLoop(fd: CInt, channelId: UInt32,
                  readBuffer: UnsafeMutablePointer<UInt8>,
                  readBufferSize: Int) async {
        while true {
            let buf = UnsafeMutableRawBufferPointer(
                start: UnsafeMutableRawPointer(readBuffer),
                count: readBufferSize
            )
            let bytesRead = await eventLoop.read(
                channelId: channelId, fd: fd, into: buf
            )
            guard bytesRead > 0 else {
                closeConnection(fd: fd)
                return
            }
            _ = loopStats.bytesReceived.add(Int64(bytesRead))
            _ = loopStats.bytesSent.add(Int64(bytesRead))

            var offset = 0
            while offset < bytesRead {
                let ptr = UnsafeRawPointer(readBuffer).advanced(by: offset)
                let len = bytesRead - offset
                let written = await eventLoop.write(
                    channelId: channelId, fd: fd,
                    from: UnsafeRawBufferPointer(start: ptr, count: len)
                )
                if written < 0 { break }
                offset += written
            }
        }
    }

    func httpLoop(fd: CInt, channelId: UInt32,
                  readBuffer: UnsafeMutablePointer<UInt8>,
                  readBufferSize: Int,
                  codec: inout HTTP1Codec) async {
        var needsRead = true
        while true {
            parseLoop: while true {
                let result = codec.tryParse()
                switch result {
                case .incomplete:
                    needsRead = true
                    break parseLoop

                case .response(let response):
                    await writeResponse(fd: fd, channelId: channelId,
                                        response: response)
                    if !response.keepAlive {
                        closeConnection(fd: fd)
                        return
                    }
                    continue parseLoop

                case .needsAsync:
                    let response = await codec.dispatchAsync()
                    await writeResponse(fd: fd, channelId: channelId,
                                        response: response)
                    if !response.keepAlive {
                        closeConnection(fd: fd)
                        return
                    }
                    continue parseLoop
                }
            }

            guard needsRead else { continue }
            let buf = UnsafeMutableRawBufferPointer(
                start: UnsafeMutableRawPointer(readBuffer),
                count: readBufferSize
            )
            let bytesRead = await eventLoop.read(
                channelId: channelId, fd: fd, into: buf
            )
            guard bytesRead > 0 else {
                closeConnection(fd: fd)
                return
            }
            _ = loopStats.bytesReceived.add(Int64(bytesRead))
            codec.feed(UnsafeBufferPointer(
                start: readBuffer, count: bytesRead))
            needsRead = false
        }
    }

    private func writeResponse(
        fd: CInt, channelId: UInt32,
        response: HTTPResponse
    ) async {
        let headerLen = response.headerBuffer.readableBytes
        let bodyLen = response.bodyBuffer?.readableBytes ?? 0
        let totalLen = headerLen + bodyLen
        _ = loopStats.bytesSent.add(Int64(totalLen))

        // ByteBuffer storage is heap-allocated and stable — pointer
        // remains valid while the ByteBuffer is alive (held in this
        // coroutine frame). This is the same zero-copy pattern as the
        // original code: the kernel reads from the ByteBuffer's
        // backing store via io_uring DMA.
        let headerBase = response.headerBuffer.withUnsafeReadableBytes { $0.baseAddress! }
        let bodyBase = response.bodyBuffer?.withUnsafeReadableBytes { $0.baseAddress! }

        var offset = 0
        while offset < totalLen {
            let remaining = totalLen - offset
            let written: Int

            if offset < headerLen {
                let len = min(headerLen - offset, remaining)
                written = await eventLoop.write(
                    channelId: channelId, fd: fd,
                    from: UnsafeRawBufferPointer(
                        start: headerBase.advanced(by: offset), count: len
                    )
                )
            } else if let bodyBase = bodyBase {
                let bodyOffset = offset - headerLen
                let len = min(bodyLen - bodyOffset, remaining)
                written = await eventLoop.write(
                    channelId: channelId, fd: fd,
                    from: UnsafeRawBufferPointer(
                        start: bodyBase.advanced(by: bodyOffset), count: len
                    )
                )
            } else {
                break
            }

            if written < 0 { break }
            offset += written
        }
    }
}

#endif // os(Linux)
