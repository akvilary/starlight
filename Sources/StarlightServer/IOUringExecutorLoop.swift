//===----------------------------------------------------------------------===//
//
//  IOUringExecutorLoop.swift
//  StarlightServer
//
//  io_uring event loop conforming to SerialExecutor — Linux only.
//
//  The loop IS the executor: connection handler Tasks run on the
//  loop thread. When a handler calls `await readAsync(...)`, the
//  continuation is enqueued back on this executor. CQE processing
//  resumes continuations inline — no thread hops for inline async.
//
//  ─── Event loop ──────────────────────────────────────────────────────
//
//    while !stopped {
//        drainJobs()        ← run connection handler continuations
//        sl_wait_cqe()      ← wait for I/O completions
//        processCQEs()      ← resume read/write continuations
//    }                        → enqueue jobs → drainJobs picks them up
//
//  ─── Thread safety ───────────────────────────────────────────────────
//
//  Ring, connections, continuations: loop thread only (no locks).
//  jobQueue: spinlock (enqueue from pool, drain on loop).
//
//===----------------------------------------------------------------------===//

#if os(Linux)

import Foundation
import CStarlightLinux
import NIOCore
import StarlightCore
import StarlightHTTP
import StarlightRouting

#if canImport(Glibc)
import Glibc
#endif

// MARK: - user_data packing (shared with old IOUringLoop)

internal enum IouringOp: UInt64 {
    case accept = 1
    case recv   = 2
    case send   = 3
    case poll   = 4
}

@inline(__always)
internal func packUserData(fd: CInt, op: IouringOp) -> UInt64 {
    UInt64(UInt32(bitPattern: fd)) | (op.rawValue << 32)
}

@inline(__always)
internal func unpackFD(_ data: UInt64) -> CInt {
    CInt(bitPattern: UInt32(truncatingIfNeeded: data))
}

@inline(__always)
internal func unpackOp(_ data: UInt64) -> IouringOp {
    IouringOp(rawValue: data >> 32) ?? .accept
}

// MARK: - ExecutorConnection

final class ExecutorConnection: @unchecked Sendable {
    let fd: CInt
    let readBuffer: UnsafeMutablePointer<UInt8>
    let codec: HTTP1Codec
    var pendingResponse: HTTPResponse?
    var sendLen: Int = 0
    var sendOffset: Int = 0
    var keepAlive: Bool = true

    init(fd: CInt, readBufferSize: Int, router: Router?, handler: HTTPHandler?) {
        self.fd = fd
        self.readBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: readBufferSize)
        if let router = router {
            self.codec = HTTP1Codec(router: router)
        } else {
            self.codec = HTTP1Codec(handler: handler!)
        }
    }

    deinit { readBuffer.deallocate() }

    func fillSendSQE(_ sqe: UnsafeMutablePointer<io_uring_sqe>, offset: Int) {
        let remaining = UInt32(sendLen - offset)
        if let r = pendingResponse {
            if r.bodyBuffer == nil {
                r.headerBuffer.withUnsafeReadableBytes { ptr in
                    sl_prep_send(sqe, fd, ptr.baseAddress!.advanced(by: offset), remaining)
                }
            } else {
                let hdr = r.headerBuffer.readableBytes
                if offset < hdr {
                    r.headerBuffer.withUnsafeReadableBytes { ptr in
                        sl_prep_send(sqe, fd, ptr.baseAddress!.advanced(by: offset), UInt32(hdr - offset))
                    }
                } else {
                    let bodyOff = offset - hdr
                    r.bodyBuffer!.withUnsafeReadableBytes { ptr in
                        sl_prep_send(sqe, fd, ptr.baseAddress!.advanced(by: bodyOff), remaining)
                    }
                }
            }
        }
    }

    func clearSend() {
        pendingResponse = nil
        sendLen = 0
        sendOffset = 0
    }
}

// MARK: - ConnectionActor

/// Runs the connection handler on the loop's executor.
/// The actor's `unownedExecutor` returns the loop's executor,
/// so all methods run on the io_uring thread.
final actor ConnectionActor {
    private nonisolated let _executor: UnownedSerialExecutor

    init(_ executor: UnownedSerialExecutor) {
        self._executor = executor
    }

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        _executor
    }

    func handle(fd: CInt, conn: ExecutorConnection,
                loop: IOUringExecutorLoop) async {
        while true {
            let bytesRead = await loop.readAsync(fd, conn: conn)
            guard bytesRead > 0 else {
                loop.closeConnection(fd: fd)
                return
            }

            conn.codec.feed(UnsafeBufferPointer(
                start: conn.readBuffer, count: bytesRead))

            let result = conn.codec.tryParseSync()
            switch result {
            case .incomplete:
                continue

            case .response(let response):
                await loop.writeAsync(fd, conn: conn, response: response)
                if !response.keepAlive {
                    loop.closeConnection(fd: fd)
                    return
                }

            case .needsAsync:
                let response = await conn.codec.dispatchAsync()
                _ = loop.loopStats.bytesSent.add(Int64(
                    response.headerBuffer.readableBytes
                    + (response.bodyBuffer?.readableBytes ?? 0)))
                await loop.writeAsync(fd, conn: conn, response: response)
                if !response.keepAlive {
                    loop.closeConnection(fd: fd)
                    return
                }
            }
        }
    }
}

// MARK: - IOUringExecutorLoop

final class IOUringExecutorLoop: @unchecked Sendable {

    private var ring = sl_ring()
    private var listenerFd: CInt = -1
    private var wakeupFd: CInt = -1

    private let host: String
    private let port: Int
    private let handler: HTTPHandler?
    private let router: Router?
    private let ringEntries: UInt32 = 4096
    private let readBufferSize: Int = 4096
    private let maxConnectionsPerLoop: Int
    internal let loopStats: ServerStats

    // Connection state (loop thread only)
    private var connections: [CInt: ExecutorConnection] = [:]
    private var connectionCount: Int = 0
    private var acceptArmed = false

    // Continuation bridges (loop thread only)
    private var readWaiters: [CInt: CheckedContinuation<Int, Never>] = [:]
    private var writeWaiters: [CInt: CheckedContinuation<CInt, Never>] = [:]

    // Job queue (thread-safe — enqueue from any thread, drain on loop)
    private var jobQueue: [UnownedJob] = []
    private var jobLock = pthread_spinlock_t()
    private var blocked = false

    private var stopped = false

    // Cached executor reference (avoids creating UnownedSerialExecutor per call)
    private lazy var cachedExecutor: UnownedSerialExecutor = {
        UnownedSerialExecutor(ordinary: self)
    }()

    init(host: String, port: Int, handler: HTTPHandler?, router: Router?,
         stats: ServerStats, maxConnectionsPerLoop: Int = 10_000) {
        self.host = host
        self.port = port
        self.handler = handler
        self.router = router
        self.loopStats = stats
        let ringCapacity = Int(ringEntries) - 4
        self.maxConnectionsPerLoop = min(maxConnectionsPerLoop, ringCapacity)
        pthread_spin_init(&jobLock, 0)
    }

    deinit {
        pthread_spin_destroy(&jobLock)
        if ring.ring_fd >= 0 { sl_ring_exit(&ring) }
        if listenerFd >= 0 { close(listenerFd) }
        if wakeupFd >= 0 { close(wakeupFd) }
    }

    // MARK: - Setup

    func setup() throws {
        let ret = sl_ring_init(&ring, ringEntries)
        guard ret == 0 else {
            throw StarlightIOError(code: Int32(ret), function: "sl_ring_init")
        }

        let lfd = host.withCString { ptr in
            sl_listen(ptr, Int32(port), Int32(1024))
        }
        guard lfd >= 0 else {
            throw StarlightIOError(code: Int32(-lfd), function: "sl_listen")
        }
        listenerFd = lfd

        let efd = eventfd(0, 2048 | 524288)
        guard efd >= 0 else {
            throw StarlightIOError(code: Int32(errno), function: "eventfd")
        }
        wakeupFd = efd

        submitAccept()
        submitWakeupPoll()
        _ = sl_submit(&ring)
    }

    // MARK: - Event loop

    func run() throws {
        while !stopped {
            // 1. Run pending connection handler continuations.
            drainJobs()

            // 2. Wait for I/O completions.
            blocked = true
            var cqe: UnsafeMutablePointer<io_uring_cqe>? = nil
            let ret = sl_wait_cqe(&ring, &cqe)
            blocked = false

            if ret < 0 {
                if -ret == EINTR || -ret == EAGAIN { continue }
                throw StarlightIOError(code: Int32(ret), function: "sl_wait_cqe")
            }
            guard let first = cqe else { continue }

            // 3. Process CQEs → resume continuations → enqueue jobs.
            var current: UnsafeMutablePointer<io_uring_cqe>? = first
            while current != nil {
                processCQE(current!)
                sl_cqe_seen(&ring)
                let n = sl_peek_cqe(&ring, &current)
                if n == 0 { break }
            }

            // 4. Resume jobs that were enqueued by CQE processing.
            //    (cont.resume in processCQE → enqueue → drainJobs next iter)
            //    But we can also run them now for lower latency:
            drainJobs()

            ensureAcceptArmed()
        }
        sl_ring_exit(&ring)
    }

    // MARK: - Job queue management

    private func drainJobs() {
        pthread_spin_lock(&jobLock)
        let jobs = jobQueue
        jobQueue.removeAll(keepingCapacity: true)
        pthread_spin_unlock(&jobLock)

        for job in jobs {
            job.runSynchronously(on: cachedExecutor)
        }
    }

    // Called by the Swift runtime when a continuation is resumed.
    // Can be called from the loop thread (inline) or pool threads.
    func enqueueJob(_ job: UnownedJob) {
        pthread_spin_lock(&jobLock)
        jobQueue.append(job)
        let needWake = blocked
        pthread_spin_unlock(&jobLock)
        if needWake { wakeup() }
    }

    // MARK: - SQE helpers (loop thread only)

    private func ensureSQE() -> UnsafeMutablePointer<io_uring_sqe>? {
        if let sqe = sl_get_sqe(&ring) { return sqe }
        _ = sl_submit(&ring)
        return sl_get_sqe(&ring)
    }

    // MARK: - CQE processing

    private func processCQE(_ cqe: UnsafeMutablePointer<io_uring_cqe>) {
        let data = sl_cqe_data(cqe)
        let res = cqe.pointee.res
        let op = unpackOp(data)

        switch op {
        case .accept: handleAccept(res: res)
        case .recv:   resumeRead(fd: unpackFD(data), bytesRead: res)
        case .send:   resumeWrite(fd: unpackFD(data), bytesWritten: res)
        case .poll:   handleWakeup()
        }
    }

    // MARK: - Accept

    private func submitAccept() {
        guard !acceptArmed else { return }
        guard let sqe = ensureSQE() else { return }
        sl_prep_accept(sqe, listenerFd)
        sl_sqe_set_data(sqe, packUserData(fd: listenerFd, op: .accept))
        acceptArmed = true
    }

    private func ensureAcceptArmed() {
        if connectionCount < maxConnectionsPerLoop && !acceptArmed {
            submitAccept()
        }
    }

    private func handleAccept(res: CInt) {
        acceptArmed = false
        while true {
            let fd = sl_accept4(listenerFd)
            if fd >= 0 {
                setupNewConnection(fd: fd)
            } else if fd == -EINTR {
                continue
            } else {
                break
            }
        }
        if connectionCount < maxConnectionsPerLoop {
            submitAccept()
        }
    }

    private func setupNewConnection(fd: CInt) {
        _ = sl_set_tcp_nodelay(fd)
        sl_set_keepalive(fd, 60, 10, 3)
        _ = loopStats.connectionsAccepted.increment()
        connectionCount += 1

        let conn = ExecutorConnection(fd: fd, readBufferSize: readBufferSize,
                                      router: router, handler: handler)
        connections[fd] = conn

        // Start connection handler on our executor.
        let actor = ConnectionActor(cachedExecutor)
        let loop = self
        Task {
            await actor.handle(fd: fd, conn: conn, loop: loop)
            // Handler returned — cleanup already done inside handle().
        }
    }

    // MARK: - Async read bridge

    /// Suspend until RECV CQE arrives. Called from ConnectionActor
    /// (on loop's executor). Ring access is safe — same thread.
    func readAsync(_ fd: CInt, conn: ExecutorConnection) async -> Int {
        return await withCheckedContinuation { cont in
            readWaiters[fd] = cont
            if let sqe = ensureSQE() {
                sl_prep_recv(sqe, fd, conn.readBuffer, UInt32(readBufferSize))
                sl_sqe_set_data(sqe, packUserData(fd: fd, op: .recv))
            } else {
                // Ring full — resume immediately with error
                cont.resume(returning: 0)
            }
        }
    }

    private func resumeRead(fd: CInt, bytesRead: CInt) {
        if bytesRead > 0 {
            _ = loopStats.bytesReceived.add(Int64(bytesRead))
        }
        if let cont = readWaiters.removeValue(forKey: fd) {
            cont.resume(returning: Int(bytesRead))
        }
    }

    // MARK: - Async write bridge

    /// Suspend until full response is sent (handles partial writes
    /// internally). Called from ConnectionActor (on loop's executor).
    func writeAsync(_ fd: CInt, conn: ExecutorConnection,
                    response: HTTPResponse) async {
        let len = response.headerBuffer.readableBytes
                   + (response.bodyBuffer?.readableBytes ?? 0)
        _ = loopStats.bytesSent.add(Int64(len))

        conn.pendingResponse = response
        conn.sendLen = len
        conn.sendOffset = 0
        conn.keepAlive = response.keepAlive

        while conn.sendOffset < conn.sendLen {
            let written: CInt = await withCheckedContinuation { cont in
                writeWaiters[fd] = cont
                if let sqe = ensureSQE() {
                    conn.fillSendSQE(sqe, offset: conn.sendOffset)
                    sl_sqe_set_data(sqe, packUserData(fd: fd, op: .send))
                } else {
                    cont.resume(returning: -1)
                }
            }

            if written < 0 {
                // Write error — stop trying
                break
            }
            conn.sendOffset += Int(written)
        }

        conn.clearSend()
    }

    private func resumeWrite(fd: CInt, bytesWritten: CInt) {
        if let cont = writeWaiters.removeValue(forKey: fd) {
            cont.resume(returning: bytesWritten)
        }
    }

    // MARK: - Wakeup (eventfd)

    private func submitWakeupPoll() {
        guard let sqe = ensureSQE() else { return }
        sl_prep_poll_add(sqe, wakeupFd, 0x0001, 1)
        sl_sqe_set_data(sqe, packUserData(fd: wakeupFd, op: .poll))
    }

    private func handleWakeup() {
        var val: UInt64 = 0
        _ = withUnsafeMutablePointer(to: &val) { ptr in read(wakeupFd, ptr, 8) }
    }

    // MARK: - Connection cleanup (called from ConnectionActor on loop thread)

    func closeConnection(fd: CInt) {
        connections.removeValue(forKey: fd)
        readWaiters.removeValue(forKey: fd)?.resume(returning: 0)
        writeWaiters.removeValue(forKey: fd)?.resume(returning: -1)
        close(fd)
        connectionCount -= 1
    }

    // MARK: - Wakeup + shutdown

    private func wakeup() {
        var val: UInt64 = 1
        _ = withUnsafePointer(to: &val) { ptr in write(wakeupFd, ptr, 8) }
    }

    func shutdown() {
        stopped = true
        wakeup()
    }
}

// MARK: - SerialExecutor conformance

extension IOUringExecutorLoop: SerialExecutor {
    func enqueue(_ job: consuming ExecutorJob) {
        let unowned = UnownedJob(job)
        enqueueJob(unowned)
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        cachedExecutor
    }

    func isSameExclusiveExecutionContext(other: IOUringExecutorLoop) -> Bool {
        other === self
    }
}

// MARK: - Error

struct StarlightIOError: Error, CustomStringConvertible {
    let code: Int32
    let function: String
    var description: String {
        "StarlightIOError(\(function)): \(String(cString: strerror(code))) [\(code)]"
    }
}

#endif // os(Linux)
