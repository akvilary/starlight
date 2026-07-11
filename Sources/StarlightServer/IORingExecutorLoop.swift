//===----------------------------------------------------------------------===//
//
//  IORingExecutorLoop.swift
//  StarlightServer
//
//  io_uring event loop conforming to SerialExecutor — Linux only.
//
//  Built on Apple SystemPackage.IORing (~Copyable ring management).
//  The loop IS the executor: connection handler Tasks run on the
//  loop thread. When a handler calls `await readAsync(...)`, the
//  continuation is enqueued back on this executor. CQE processing
//  resumes continuations inline — no thread hops for inline async.
//
//  ─── Event loop ──────────────────────────────────────────────────────
//
//    while !stopped {
//        drainCQEs()         ← tryConsumeCompletion (0 syscalls)
//        submit OR wait      ← 1 syscall
//        drainJobs()         ← run connection handler continuations
//    }
//
//  ─── Wakeup ──────────────────────────────────────────────────────────
//
//  eventfd is armed via Request.read through the ring. Accept thread
//  and pool threads write to eventfd → CQE fires → loop wakes.
//  No POLL_ADD needed — Request.read on eventfd replaces it.
//
//  ─── Accept ──────────────────────────────────────────────────────────
//
//  Dedicated accept thread: poll(listener) → drain accept4 → signal.
//  Same CPU as loop thread (thread-per-core).
//
//  ─── Thread safety ───────────────────────────────────────────────────
//
//  Ring, connections, continuations: loop thread only (no locks).
//  newConnQueue: spinlock (accept thread → loop thread).
//  poolJobs: spinlock (pool threads → loop thread).
//
//===----------------------------------------------------------------------===//

#if os(Linux) && compiler(>=6.2) && $Lifetimes

import Foundation
import SystemPackage
import CLinuxExt
import NIOCore
import StarlightCore
import StarlightHTTP
import StarlightRouting

#if canImport(Glibc)
import Glibc
#endif

// MARK: - user_data packing

internal enum IouringOp: UInt64 {
    case wakeup = 0
    case recv   = 1
    case send   = 2
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
    IouringOp(rawValue: data >> 32) ?? .wakeup
}

// MARK: - ExecutorConnection

final class ExecutorConnection: @unchecked Sendable {
    let fd: CInt
    let readBuffer: UnsafeMutablePointer<UInt8>
    let readBufferSize: Int
    let codec: HTTP1Codec
    var pendingResponse: HTTPResponse?
    var sendLen: Int = 0
    var sendOffset: Int = 0
    var keepAlive: Bool = true

    init(fd: CInt, readBufferSize: Int, router: Router?, handler: HTTPHandler?) {
        self.fd = fd
        self.readBufferSize = readBufferSize
        self.readBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: readBufferSize)
        if let router = router {
            self.codec = HTTP1Codec(router: router)
        } else {
            self.codec = HTTP1Codec(handler: handler!)
        }
    }

    deinit { readBuffer.deallocate() }

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
                loop: IORingExecutorLoop) async {
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

// MARK: - IORingExecutorLoop

final class IORingExecutorLoop: @unchecked Sendable {

    // IORing (~Copyable, owned by this class — deinit'd automatically)
    private var ring: IORing

    private var listenerFd: CInt = -1
    private var eventFd: CInt = -1

    private let host: String
    private let port: Int
    private let handler: HTTPHandler?
    private let router: Router?
    private let queueDepth: UInt32 = 4096
    private let readBufferSize: Int = 4096
    private let maxConnectionsPerLoop: Int
    private let cpuIndex: CInt
    internal let loopStats: ServerStats

    // Connection state (loop thread only)
    private var connections: [CInt: ExecutorConnection] = [:]
    private var connectionCount: Int = 0

    // Continuation bridges (loop thread only)
    private var readWaiters: [CInt: CheckedContinuation<Int, Never>] = [:]
    private var writeWaiters: [CInt: CheckedContinuation<Int, Never>] = [:]

    // New connection queue (accept thread → loop thread, spinlock)
    private var newConnQueue: [CInt] = []
    private var newConnLock = pthread_spinlock_t()

    // Job queues — split by source thread (same pattern as original)
    private var loopJobs: [UnownedJob] = []
    private var poolJobs: [UnownedJob] = []
    private var jobLock = pthread_spinlock_t()
    private var loopThreadId: pthread_t? = nil

    // Wakeup eventfd read buffer (pre-allocated, reused)
    private let wakeupBuffer: UnsafeMutableRawPointer =
        .allocate(byteCount: 8, alignment: 8)

    private var stopped = false

    // True when ring.prepare() succeeded since last submitPreparedRequests().
    // Avoids no-op io_uring_enter syscalls on idle iterations.
    private var needsSubmit = false

    // Cached executor (created lazily on first access from loop thread)
    private var _cachedExecutor: UnownedSerialExecutor? = nil
    var cachedExecutor: UnownedSerialExecutor {
        if let ce = _cachedExecutor { return ce }
        let ce = UnownedSerialExecutor(ordinary: self)
        _cachedExecutor = ce
        return ce
    }

    // MARK: Init

    init(host: String, port: Int, handler: HTTPHandler?, router: Router?,
         stats: ServerStats, cpuIndex: CInt) throws {
        self.host = host
        self.port = port
        self.handler = handler
        self.router = router
        self.loopStats = stats
        self.cpuIndex = cpuIndex
        self.maxConnectionsPerLoop = Int(4096) - 8

        pthread_spin_init(&newConnLock, 0)
        pthread_spin_init(&jobLock, 0)

        // Ring init last — if this throws, init fails (no partial object).
        // NOTE: SINGLE_ISSUER is not used because the ring is created in init
        // (main thread) but submitted from run() (loop thread). To enable
        // SINGLE_ISSUER, ring creation must move to run().
        self.ring = try IORing(
            queueDepth: queueDepth,
            flags: []
        )
    }

    deinit {
        // ring's deinit runs automatically (munmap + close).
        if listenerFd >= 0 { Glibc.close(listenerFd) }
        if eventFd >= 0 { Glibc.close(eventFd) }
        wakeupBuffer.deallocate()
        pthread_spin_destroy(&newConnLock)
        pthread_spin_destroy(&jobLock)
    }

    // MARK: Setup

    func setup() throws {
        // Create listener (non-blocking, SO_REUSEPORT).
        let lfd = linuxCreateListener(host: host, port: port)
        guard lfd >= 0 else {
            throw StarlightIOError(code: Int32(-lfd), function: "linuxCreateListener")
        }
        listenerFd = lfd

        // Create eventfd for wakeup.
        let efd = sl_eventfd(0, LinuxSocketConst.EFD_NONBLOCK | LinuxSocketConst.EFD_CLOEXEC)
        guard efd >= 0 else {
            throw StarlightIOError(code: Int32(errno), function: "eventfd")
        }
        eventFd = efd

        // Arm wakeup read on ring. When accept thread / pool thread writes
        // to eventfd, this read completes → CQE wakes the loop.
        armWakeup()

        // Submit initial requests.
        try submitPending()
    }

    // MARK: Event loop

    func run() throws {
        loopThreadId = pthread_self()
        defer { loopThreadId = nil }

        // Start accept thread (same CPU).
        Thread.detachNewThread { [self] in
            sl_pin_to_cpu(self.cpuIndex)
            self.acceptThreadMain()
        }

        while !stopped {
            // Phase 1: drain CQEs from mmap memory (0 syscalls).
            var drainedAny = false
            while let cqe = ring.tryConsumeCompletion() {
                processCQE(cqe)
                drainedAny = true
            }

            // Phase 2a: submit pending SQEs if any (1 syscall only when needed).
            if needsSubmit {
                try submitPending()
                needsSubmit = false
            }

            // Phase 2b: if no CQEs were found in memory, block for the next.
            if !drainedAny {
                do {
                    let cqe = try ring.blockingConsumeCompletion()
                    processCQE(cqe)
                } catch {
                    // Spurious wakeup or signal — just loop.
                }
            }

            // Phase 3: drain jobs (continuation resumes, new Tasks).
            drainJobs()
        }
    }

    // MARK: CQE processing

    @inline(__always)
    private func processCQE(_ cqe: borrowing IORing.Completion) {
        let ctx = cqe.context
        let res = cqe.result
        let op = unpackOp(ctx)

        switch op {
        case .wakeup:
            handleWakeup()
        case .recv:
            resumeRead(fd: unpackFD(ctx), bytesRead: res)
        case .send:
            resumeWrite(fd: unpackFD(ctx), bytesWritten: res)
        }
    }

    // MARK: Wakeup handling

    @inline(__always)
    private func handleWakeup() {
        _ = Glibc.read(eventFd, wakeupBuffer, 8)
        armWakeup()

        var fds: [CInt] = []
        pthread_spin_lock(&newConnLock)
        swap(&newConnQueue, &fds)
        pthread_spin_unlock(&newConnLock)

        for fd in fds {
            setupNewConnection(fd)
        }
    }

    @inline(__always)
    private func armWakeup() {
        let ok = ring.prepare(request: .read(
            FileDescriptor(rawValue: eventFd),
            into: UnsafeMutableRawBufferPointer(start: wakeupBuffer, count: 8),
            context: packUserData(fd: eventFd, op: .wakeup)
        ))
        if ok { needsSubmit = true }
    }

    // MARK: Accept thread

    private func acceptThreadMain() {
        while !stopped {
            var pfd = pollfd(fd: listenerFd, events: LinuxSocketConst.POLLIN, revents: 0)
            let ret = Glibc.poll(&pfd, 1, 100)
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
                var val: UInt64 = 1
                _ = withUnsafePointer(to: &val) { ptr in
                    Glibc.write(eventFd, ptr, 8)
                }
            }
        }
    }

    // MARK: New connection setup

    private func setupNewConnection(_ fd: CInt) {
        _ = loopStats.connectionsAccepted.increment()
        connectionCount += 1

        let conn = ExecutorConnection(fd: fd, readBufferSize: readBufferSize,
                                       router: router, handler: handler)
        connections[fd] = conn

        let actor = ConnectionActor(cachedExecutor)
        let loop = self
        Task {
            await actor.handle(fd: fd, conn: conn, loop: loop)
        }
    }

    // MARK: SQE submission

    @inline(__always)
    private func submitPending() throws {
        do {
            try ring.submitPreparedRequests()
        } catch {
            // Non-fatal — ring will retry on next iteration.
        }
    }

    // MARK: Async read bridge

    func readAsync(_ fd: CInt, conn: ExecutorConnection) async -> Int {
        return await withCheckedContinuation { cont in
            let buf = UnsafeMutableRawBufferPointer(
                start: UnsafeMutableRawPointer(conn.readBuffer),
                count: conn.readBufferSize
            )
            if ring.prepare(request: .read(
                FileDescriptor(rawValue: fd),
                into: buf,
                context: packUserData(fd: fd, op: .recv)
            )) {
                needsSubmit = true
                readWaiters[fd] = cont
            } else {
                cont.resume(returning: 0)
            }
        }
    }

    @inline(__always)
    private func resumeRead(fd: CInt, bytesRead: CInt) {
        if bytesRead > 0 {
            _ = loopStats.bytesReceived.add(Int64(bytesRead))
        }
        if let cont = readWaiters.removeValue(forKey: fd) {
            cont.resume(returning: Int(bytesRead))
        }
    }

    // MARK: Async write bridge

    func writeAsync(_ fd: CInt, conn: ExecutorConnection,
                    response: HTTPResponse) async {
        let headerLen = response.headerBuffer.readableBytes
        let bodyLen = response.bodyBuffer?.readableBytes ?? 0
        let totalLen = headerLen + bodyLen
        _ = loopStats.bytesSent.add(Int64(totalLen))

        conn.pendingResponse = response
        conn.sendLen = totalLen
        conn.sendOffset = 0
        conn.keepAlive = response.keepAlive

        while conn.sendOffset < conn.sendLen {
            let written: Int = await withCheckedContinuation { (cont: CheckedContinuation<Int, Never>) in
                prepareWriteSQE(fd: fd, conn: conn, cont: cont)
            }
            if written < 0 { break }
            conn.sendOffset += written
        }

        conn.clearSend()
    }

    private func prepareWriteSQE(fd: CInt, conn: ExecutorConnection,
                                  cont: CheckedContinuation<Int, Never>) {
        guard let response = conn.pendingResponse else {
            cont.resume(returning: -1)
            return
        }
        let headerLen = response.headerBuffer.readableBytes
        let remaining = conn.sendLen - conn.sendOffset

        if conn.sendOffset < headerLen {
            let offset = conn.sendOffset
            response.headerBuffer.withUnsafeReadableBytes { rawBuf in
                let len = min(rawBuf.count - offset, remaining)
                let ptr = UnsafeMutableRawPointer(mutating: rawBuf.baseAddress!)
                    .advanced(by: offset)
                let ok = ring.prepare(request: .write(
                    UnsafeMutableRawBufferPointer(start: ptr, count: len),
                    into: FileDescriptor(rawValue: fd),
                    context: packUserData(fd: fd, op: .send)
                ))
                if ok { needsSubmit = true; writeWaiters[fd] = cont }
                else { cont.resume(returning: -1) }
            }
        } else if let bodyBuf = response.bodyBuffer {
            let bodyOffset = conn.sendOffset - headerLen
            bodyBuf.withUnsafeReadableBytes { rawBuf in
                let len = min(rawBuf.count - bodyOffset, remaining)
                let ptr = UnsafeMutableRawPointer(mutating: rawBuf.baseAddress!)
                    .advanced(by: bodyOffset)
                let ok = ring.prepare(request: .write(
                    UnsafeMutableRawBufferPointer(start: ptr, count: len),
                    into: FileDescriptor(rawValue: fd),
                    context: packUserData(fd: fd, op: .send)
                ))
                if ok { needsSubmit = true; writeWaiters[fd] = cont }
                else { cont.resume(returning: -1) }
            }
        } else {
            cont.resume(returning: -1)
        }
    }

    @inline(__always)
    private func resumeWrite(fd: CInt, bytesWritten: CInt) {
        if let cont = writeWaiters.removeValue(forKey: fd) {
            cont.resume(returning: Int(bytesWritten))
        }
    }

    // MARK: Connection cleanup

    func closeConnection(fd: CInt) {
        connections.removeValue(forKey: fd)
        readWaiters.removeValue(forKey: fd)?.resume(returning: 0)
        writeWaiters.removeValue(forKey: fd)?.resume(returning: -1)
        Glibc.close(fd)
        connectionCount -= 1
    }

    // MARK: Job queue management

    private func drainJobs() {
        var jobs = loopJobs
        loopJobs.removeAll(keepingCapacity: true)

        if !poolJobs.isEmpty {
            pthread_spin_lock(&jobLock)
            jobs.append(contentsOf: poolJobs)
            poolJobs.removeAll(keepingCapacity: true)
            pthread_spin_unlock(&jobLock)
        }

        for job in jobs {
            job.runSynchronously(on: cachedExecutor)
        }
    }

    func enqueueJob(_ job: UnownedJob) {
        if pthread_self() == loopThreadId {
            loopJobs.append(job)
        } else {
            pthread_spin_lock(&jobLock)
            poolJobs.append(job)
            let needWake = loopThreadId != nil
            pthread_spin_unlock(&jobLock)
            if needWake { wakeup() }
        }
    }

    // MARK: Wakeup + shutdown

    private func wakeup() {
        var val: UInt64 = 1
        _ = withUnsafePointer(to: &val) { ptr in
            Glibc.write(eventFd, ptr, 8)
        }
    }

    func shutdown() {
        stopped = true
        wakeup()
    }
}

// MARK: - SerialExecutor conformance

extension IORingExecutorLoop: SerialExecutor {
    func enqueue(_ job: consuming ExecutorJob) {
        let unowned = UnownedJob(job)
        enqueueJob(unowned)
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        cachedExecutor
    }

    func isSameExclusiveExecutionContext(other: IORingExecutorLoop) -> Bool {
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

#endif // os(Linux) && compiler(>=6.2) && $Lifetimes
