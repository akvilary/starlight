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

// MARK: - ExecutorConnection
//
// Identical to the io_uring variant but renamed to avoid an ambiguous
// type lookup when both backends are compiled in (Linux + Lifetimes).
// A future cleanup would extract these into a shared file with a
// protocol that both IORingExecutorLoop and EpollExecutorLoop conform
// to — but for now we keep the io_uring path untouched.

final class EpollConnection: @unchecked Sendable {
    let channelId: UInt32
    let fd: CInt
    let readBuffer: UnsafeMutablePointer<UInt8>
    let readBufferSize: Int
    let codec: HTTP1Codec?

    init(channelId: UInt32, fd: CInt, readBufferSize: Int, isEchoMode: Bool,
         router: Router?, handler: HTTPHandler?) {
        self.channelId = channelId
        self.fd = fd
        self.readBufferSize = readBufferSize
        self.readBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: readBufferSize)
        if isEchoMode {
            self.codec = nil
        } else if let router = router {
            self.codec = HTTP1Codec(router: router)
        } else {
            self.codec = HTTP1Codec(handler: handler!)
        }
    }

    deinit { readBuffer.deallocate() }
}

// MARK: - ConnectionActor

final actor EpollConnectionActor {
    nonisolated let _executor: UnownedSerialExecutor

    init(_ executor: UnownedSerialExecutor) {
        self._executor = executor
    }

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        _executor
    }

    func handle(fd: CInt, conn: EpollConnection,
                loop: EpollExecutorLoop) async {
        if conn.codec == nil {
            await loop.echoLoop(fd: fd, conn: conn)
        } else {
            await loop.httpLoop(fd: fd, conn: conn)
        }
    }
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
    private var connections: [CInt: EpollConnection] = [:]
    private var connectionCount: Int = 0
    private var newConnQueue: [CInt] = []
    private var newConnLock = pthread_spinlock_t()
    private var connActor: EpollConnectionActor? = nil

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
            throw PollError(code: Int32(-lfd), function: "linuxCreateListener")
        }
        listenerFd = lfd
    }

    // MARK: Run (delegates to PollEventLoop)

    func run() throws {
        eventLoop.onWakeup = { [self] in
            self.handleNewConnections()
        }

        // Start accept thread (separate from the event loop thread).
        Thread.detachNewThread { [self] in
            self.acceptThreadMain()
        }

        try eventLoop.run()

        drainConnections()
    }

    func shutdown() {
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
        let conn = EpollConnection(
            channelId: channelId, fd: fd,
            readBufferSize: readBufferSize,
            isEchoMode: isEchoMode,
            router: router, handler: handler
        )
        connections[fd] = conn

        if connActor == nil {
            connActor = EpollConnectionActor(eventLoop.cachedExecutor)
        }
        Task {
            await connActor!.handle(fd: fd, conn: conn, loop: self)
        }
    }

    // MARK: Connection cleanup

    func closeConnection(fd: CInt) {
        if let conn = connections.removeValue(forKey: fd) {
            connectionCount -= 1
            eventLoop.cancelChannel(conn.channelId)
        }
        Glibc.close(fd)
    }

    private func drainConnections() {
        for (_, conn) in connections {
            eventLoop.cancelChannel(conn.channelId)
            Glibc.close(conn.fd)
        }
        connections.removeAll()
        connectionCount = 0
    }

    // MARK: Connection loops

    func echoLoop(fd: CInt, conn: EpollConnection) async {
        while true {
            let buf = UnsafeMutableRawBufferPointer(
                start: UnsafeMutableRawPointer(conn.readBuffer),
                count: conn.readBufferSize
            )
            let bytesRead = await eventLoop.read(
                channelId: conn.channelId, fd: fd, into: buf
            )
            guard bytesRead > 0 else {
                closeConnection(fd: fd)
                return
            }
            _ = loopStats.bytesReceived.add(Int64(bytesRead))
            _ = loopStats.bytesSent.add(Int64(bytesRead))

            var offset = 0
            while offset < bytesRead {
                let ptr = UnsafeRawPointer(conn.readBuffer).advanced(by: offset)
                let len = bytesRead - offset
                let written = await eventLoop.write(
                    channelId: conn.channelId, fd: fd,
                    from: UnsafeRawBufferPointer(start: ptr, count: len)
                )
                if written < 0 { break }
                offset += written
            }
        }
    }

    func httpLoop(fd: CInt, conn: EpollConnection) async {
        let codec = conn.codec!
        var needsRead = true
        while true {
            parseLoop: while true {
                let result = codec.tryParseSync()
                switch result {
                case .incomplete:
                    needsRead = true
                    break parseLoop

                case .response(let response):
                    await writeResponse(fd, conn, response)
                    if !response.keepAlive {
                        closeConnection(fd: fd)
                        return
                    }
                    continue parseLoop

                case .needsAsync:
                    let response = await codec.dispatchAsync()
                    await writeResponse(fd, conn, response)
                    if !response.keepAlive {
                        closeConnection(fd: fd)
                        return
                    }
                    continue parseLoop
                }
            }

            guard needsRead else { continue }
            let buf = UnsafeMutableRawBufferPointer(
                start: UnsafeMutableRawPointer(conn.readBuffer),
                count: conn.readBufferSize
            )
            let bytesRead = await eventLoop.read(
                channelId: conn.channelId, fd: fd, into: buf
            )
            guard bytesRead > 0 else {
                closeConnection(fd: fd)
                return
            }
            _ = loopStats.bytesReceived.add(Int64(bytesRead))
            codec.feed(UnsafeBufferPointer(
                start: conn.readBuffer, count: bytesRead))
            needsRead = false
        }
    }

    private func writeResponse(
        _ fd: CInt, _ conn: EpollConnection,
        _ response: HTTPResponse
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
                    channelId: conn.channelId, fd: fd,
                    from: UnsafeRawBufferPointer(
                        start: headerBase.advanced(by: offset), count: len
                    )
                )
            } else if let bodyBase = bodyBase {
                let bodyOffset = offset - headerLen
                let len = min(bodyLen - bodyOffset, remaining)
                written = await eventLoop.write(
                    channelId: conn.channelId, fd: fd,
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
