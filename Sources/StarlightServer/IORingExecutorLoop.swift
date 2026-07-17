//===----------------------------------------------------------------------===//
//
//  IORingExecutorLoop.swift
//  StarlightServer
//
//  HTTP-specific event loop built on StarlightIORing.IORingEventLoop.
//  Manages accept, connections, and HTTP/echo protocol loops.
//  Delegates generic async I/O to IORingEventLoop.
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

#if os(Linux) && compiler(>=6.2) && $Lifetimes

import Foundation
import SystemPackage
import CLinuxExt
import NIOCore
import StarlightCore
import StarlightIORing
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

struct IORingConnectionState: Sendable {
    let channelId: UInt32
}

// MARK: - IORingExecutorLoop (HTTP-specific wrapper around IORingEventLoop)

final class IORingExecutorLoop: @unchecked Sendable {

    let eventLoop: IORingEventLoop
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
    /// fd → channelId of every active connection. Used by shutdown's
    /// drainConnections() to cancel channels. Mutated only on the loop
    /// thread.
    private var connections: [CInt: IORingConnectionState] = [:]
    private var connectionCount: Int = 0
    private var newConnQueue: [CInt] = []
    private var newConnLock = pthread_spinlock_t()

    // MARK: Init

    init(host: String, port: Int, mode: Mode,
         handler: HTTPHandler?, router: Router?,
         stats: ServerStats, cpuIndex: CInt) {
        self.eventLoop = IORingEventLoop(queueDepth: 4096)
        self.host = host
        self.port = port
        self.isEchoMode = (mode == .tcpEcho)
        self.handler = handler
        self.router = router
        self.loopStats = stats
        self.cpuIndex = cpuIndex
        self.maxConnectionsPerLoop = Int(4096) - 8

        pthread_spin_init(&newConnLock, 0)
    }

    deinit {
        if listenerFd >= 0 { Glibc.close(listenerFd) }
        pthread_spin_destroy(&newConnLock)
    }

    // MARK: Setup

    func setup() throws {
        let lfd = linuxCreateListener(host: host, port: port)
        guard lfd >= 0 else {
            throw IORingError(code: Int32(-lfd), function: "linuxCreateListener")
        }
        listenerFd = lfd
    }

    // MARK: Run (delegates to IORingEventLoop)

    func run() throws {
        // `[weak self]` + explicit `onWakeup = nil` in `shutdown()`
        // breaks the retain cycle:
        //   IORingExecutorLoop ─strong→ eventLoop
        //   ─strong→ onWakeup closure ─strong→ IORingExecutorLoop
        // Without this the deinit never runs and listenerFd,
        // newConnQueue, readBuffers, and the accept pthread leak for
        // the lifetime of the process.
        eventLoop.onWakeup = { [weak self] in
            self?.handleNewConnections()
        }

        // Start accept thread (separate from the event loop thread).
        // `[weak self]` so the thread doesn't keep the loop alive if
        // shutdown() raced ahead; the `self?` guard lets the thread
        // exit cleanly when the loop is gone.
        Thread.detachNewThread { [weak self] in
            self?.acceptThreadMain()
        }

        try eventLoop.run()

        drainConnections()
    }

    func shutdown() {
        // Tear down the wakeup closure before stopping the loop —
        // releases the closure that captures `self` and breaks the
        // retain cycle unconditionally. Idempotent.
        eventLoop.onWakeup = nil
        eventLoop.shutdown()
    }

    // MARK: Accept thread

    private func acceptThreadMain() {
        while !eventLoop.isStopped {
            var pfd = pollfd(fd: listenerFd, events: LinuxSocketConst.POLLIN, revents: 0)
            let ret = Glibc.poll(&pfd, 1, 1000)
            if ret <= 0 { continue }
            if (pfd.revents & LinuxSocketConst.POLLIN) == 0 { continue }

            var accepted = false
            while true {
                let fd = sl_accept4(listenerFd)
                if fd < 0 { break }
                _ = linuxSetTcpNoDelay(fd)
                linuxSetKeepalive(fd)

                pthread_spin_lock(&newConnLock)
                newConnQueue.append(fd)
                pthread_spin_unlock(&newConnLock)
                accepted = true
            }

            if accepted {
                eventLoop.wakeup()
            }
        }
    }

    // MARK: New connection handling (called on loop thread via onWakeup)

    private func handleNewConnections() {
        var fds: [CInt] = []
        pthread_spin_lock(&newConnLock)
        swap(&newConnQueue, &fds)
        pthread_spin_unlock(&newConnLock)

        for fd in fds {
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
        connections[fd] = IORingConnectionState(channelId: channelId)

        // Spawn a Task pinned directly to the loop via TaskExecutor
        // (SE-0431). No actor wrapper needed — `executorPreference`
        // enqueues the Task's first job onto the loop, and subsequent
        // continuations resume on the same loop thread. State is owned
        // by the Task frame: readBuffer allocated here, codec
        // constructed here.
        let isEchoMode = self.isEchoMode
        let readBufferSize = self.readBufferSize
        let router = self.router
        let handler = self.handler
        Task(executorPreference: eventLoop) { [weak self] in
            // Per-connection read buffer — owned by this Task,
            // deallocated on exit.
            let readBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: readBufferSize)
            defer { readBuffer.deallocate() }

            if isEchoMode {
                await self?.echoLoop(fd: fd, channelId: channelId,
                                      readBuffer: readBuffer,
                                      readBufferSize: readBufferSize)
            } else {
                let codec: HTTP1Codec
                if let router = router {
                    codec = HTTP1Codec(router: router)
                } else {
                    codec = HTTP1Codec(handler: handler!)
                }
                await self?.httpLoop(fd: fd, channelId: channelId,
                                     readBuffer: readBuffer,
                                     readBufferSize: readBufferSize,
                                     codec: codec)
            }
        }
    }

    // MARK: Connection cleanup

    /// Idempotent: if the fd is still in the connections table, remove
    /// it, cancel its channel, and close the fd exactly once.
    //
    // The fd is closed ONLY when it was found in the table. A missing
    // entry means drainConnections() (or another closeConnection) has
    // already closed it — calling close(fd) again on a recycled fd
    // would be a use-after-free.
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
                  codec: HTTP1Codec) async {
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

#endif // os(Linux) && compiler(>=6.2) && $Lifetimes
