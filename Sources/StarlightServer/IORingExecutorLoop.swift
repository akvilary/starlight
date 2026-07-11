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
//  ─── SINGLE_ISSUER ───────────────────────────────────────────────────
//
//  The ring is created inside run() on the loop thread, enabling
//  IORING_SETUP_SINGLE_ISSUER for kernel-side optimizations.
//
//  ─── Wakeup ──────────────────────────────────────────────────────────
//
//  eventfd is armed via Request.read through the ringBox!.ring. Accept thread
//  and pool threads write to eventfd → CQE fires → loop wakes.
//  No POLL_ADD needed — Request.read on eventfd replaces it.
//
//  ─── Accept ──────────────────────────────────────────────────────────
//
//  Dedicated accept thread: poll(listener) → drain accept4 → signal.
//  Same CPU as loop thread (thread-per-core).
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

// MARK: - IORingBox (class wrapper for ~Copyable IORing)

/// Wraps the ~Copyable IORing in a Copyable class so it can be stored
/// as an Optional and created lazily on the loop thread (SINGLE_ISSUER).
final class IORingBox: @unchecked Sendable {
    var ring: IORing

    init(queueDepth: UInt32, flags: IORing.SetupFlags) throws {
        self.ring = try IORing(queueDepth: queueDepth, flags: flags)
    }
}

// MARK: - ExecutorConnection

final class ExecutorConnection: @unchecked Sendable {
    let fd: CInt
    let readBuffer: UnsafeMutablePointer<UInt8>
    let readBufferSize: Int
    let codec: HTTP1Codec?
    var pendingResponse: HTTPResponse?
    var sendLen: Int = 0
    var sendOffset: Int = 0
    var keepAlive: Bool = true

    init(fd: CInt, readBufferSize: Int, isEchoMode: Bool,
         router: Router?, handler: HTTPHandler?) {
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
        if conn.codec == nil {
            await echoLoop(fd: fd, conn: conn, loop: loop)
        } else {
            await httpLoop(fd: fd, conn: conn, loop: loop)
        }
    }

    // TCP echo — no codec, no parsing, just bounce bytes.
    private func echoLoop(fd: CInt, conn: ExecutorConnection,
                          loop: IORingExecutorLoop) async {
        while true {
            let bytesRead = await loop.readAsync(fd, conn: conn)
            guard bytesRead > 0 else {
                loop.closeConnection(fd: fd)
                return
            }
            await loop.echoAsync(fd, conn: conn, bytesRead: bytesRead)
        }
    }

    // HTTP/1.1 — feed codec, parse, dispatch.
    private func httpLoop(fd: CInt, conn: ExecutorConnection,
                          loop: IORingExecutorLoop) async {
        let codec = conn.codec!
        while true {
            let bytesRead = await loop.readAsync(fd, conn: conn)
            guard bytesRead > 0 else {
                loop.closeConnection(fd: fd)
                return
            }

            codec.feed(UnsafeBufferPointer(
                start: conn.readBuffer, count: bytesRead))

            let result = codec.tryParseSync()
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
                let response = await codec.dispatchAsync()
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

    // IORing wrapped in a class for Optional storage.
    // Created in run() on the loop thread for SINGLE_ISSUER.
    private var ringBox: IORingBox?

    private var listenerFd: CInt = -1
    private var eventFd: CInt = -1

    private let host: String
    private let port: Int
    private let handler: HTTPHandler?
    private let router: Router?
    private let isEchoMode: Bool
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

    // Job queues — split by source thread
    private var loopJobs: [UnownedJob] = []
    private var poolJobs: [UnownedJob] = []
    private var jobLock = pthread_spinlock_t()
    private var loopThreadId: pthread_t? = nil

    // Wakeup eventfd read buffer (pre-allocated, reused)
    private let wakeupBuffer: UnsafeMutableRawPointer =
        .allocate(byteCount: 8, alignment: 8)

    private var stopped = false

    // True when ringBox!.ring.prepare() succeeded since last submitPreparedRequests().
    private var needsSubmit = false

    // Cached executor
    private var _cachedExecutor: UnownedSerialExecutor? = nil
    var cachedExecutor: UnownedSerialExecutor {
        if let ce = _cachedExecutor { return ce }
        let ce = UnownedSerialExecutor(ordinary: self)
        _cachedExecutor = ce
        return ce
    }

    // MARK: Init (no ring creation — deferred to run())

    init(host: String, port: Int, mode: Mode,
         handler: HTTPHandler?, router: Router?,
         stats: ServerStats, cpuIndex: CInt) {
        self.host = host
        self.port = port
        self.isEchoMode = (mode == .tcpEcho)
        self.handler = handler
        self.router = router
        self.loopStats = stats
        self.cpuIndex = cpuIndex
        self.maxConnectionsPerLoop = Int(4096) - 8

        pthread_spin_init(&newConnLock, 0)
        pthread_spin_init(&jobLock, 0)
    }

    deinit {
        // ringBox?.ring's deinit runs automatically (munmap + close).
        if listenerFd >= 0 { Glibc.close(listenerFd) }
        if eventFd >= 0 { Glibc.close(eventFd) }
        wakeupBuffer.deallocate()
        pthread_spin_destroy(&newConnLock)
        pthread_spin_destroy(&jobLock)
    }

    // MARK: Setup (listener + eventfd — no ring)

    func setup() throws {
        let lfd = linuxCreateListener(host: host, port: port)
        guard lfd >= 0 else {
            throw StarlightIOError(code: Int32(-lfd), function: "linuxCreateListener")
        }
        listenerFd = lfd

        let efd = sl_eventfd(0, LinuxSocketConst.EFD_NONBLOCK | LinuxSocketConst.EFD_CLOEXEC)
        guard efd >= 0 else {
            throw StarlightIOError(code: Int32(errno), function: "eventfd")
        }
        eventFd = efd
    }

    // MARK: Event loop (creates ring on THIS thread for SINGLE_ISSUER)

    func run() throws {
        loopThreadId = pthread_self()
        defer { loopThreadId = nil }

        // Create ring on the loop thread — SINGLE_ISSUER requires this.
        self.ringBox = try IORingBox(
            queueDepth: queueDepth,
            flags: [.singleSubmissionThread]
        )

        // Arm wakeup — Phase 2a of the first iteration will submit it.
        armWakeup()

        // Start accept thread (same CPU — mostly idle in poll).
        Thread.detachNewThread { [self] in
            sl_pin_to_cpu(self.cpuIndex)
            self.acceptThreadMain()
        }

        while !stopped {
            // Phase 1: Drain CQEs from mmap memory (0 syscalls).
            var drainedAny = false
            while let cqe = ringBox!.ring.tryConsumeCompletion() {
                processCQE(cqe)
                drainedAny = true
            }

            // Phase 2a: Submit pending SQEs (1 syscall only when needed).
            if needsSubmit {
                try submitPending()
                needsSubmit = false
            }

            // Phase 2b: Block only if nothing drained (0-1 syscalls).
            if !drainedAny {
                do {
                    let cqe = try ringBox!.ring.blockingConsumeCompletion()
                    processCQE(cqe)
                } catch {
                    // Spurious wakeup or signal — just loop.
                }
            }

            // Phase 3: Drain jobs — CRITICAL: runs AFTER CQE processing
            // so jobs from blockingConsumeCompletion are handled in THIS
            // iteration, not the next.
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
        let ok = ringBox!.ring.prepare(request: .read(
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
                var val: UInt64 = 1
                _ = withUnsafePointer(to: &val) { ptr in
                    Glibc.write(eventFd, ptr, 8)
                }
            }
        }
    }

    // MARK: New connection setup

    private func setupNewConnection(_ fd: CInt) {
        guard connectionCount < maxConnectionsPerLoop else {
            Glibc.close(fd)
            return
        }
        _ = loopStats.connectionsAccepted.increment()
        connectionCount += 1

        let conn = ExecutorConnection(fd: fd, readBufferSize: readBufferSize,
                                       isEchoMode: isEchoMode,
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
            try ringBox!.ring.submitPreparedRequests()
        } catch {
            // Non-fatal — ring will retry on next iteration.
        }
    }

    // MARK: Async read bridge

    /// Suspend until RECV CQE arrives. Called from ConnectionActor
    /// (on loop's executor). Ring access is safe — same thread.
    func readAsync(_ fd: CInt, conn: ExecutorConnection) async -> Int {
        return await withCheckedContinuation { cont in
            let buf = UnsafeMutableRawBufferPointer(
                start: UnsafeMutableRawPointer(conn.readBuffer),
                count: conn.readBufferSize
            )
            if ringBox!.ring.prepare(request: .read(
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

    // MARK: Async echo write (TCP echo mode)

    /// Write back exactly the bytes that were just read. No HTTP,
    /// no codec — bounce bytes directly from readBuffer.
    func echoAsync(_ fd: CInt, conn: ExecutorConnection, bytesRead: Int) async {
        _ = loopStats.bytesSent.add(Int64(bytesRead))
        conn.sendLen = bytesRead
        conn.sendOffset = 0

        while conn.sendOffset < bytesRead {
            let written: Int = await withCheckedContinuation { (cont: CheckedContinuation<Int, Never>) in
                let ptr = UnsafeMutableRawPointer(conn.readBuffer)
                    .advanced(by: conn.sendOffset)
                let len = bytesRead - conn.sendOffset
                let ok = ringBox!.ring.prepare(request: .write(
                    UnsafeMutableRawBufferPointer(start: ptr, count: len),
                    into: FileDescriptor(rawValue: fd),
                    context: packUserData(fd: fd, op: .send)
                ))
                if ok { needsSubmit = true; writeWaiters[fd] = cont }
                else { cont.resume(returning: -1) }
            }
            if written < 0 { break }
            conn.sendOffset += written
        }
    }

    // MARK: Async HTTP write bridge

    /// Suspend until full response is sent (handles partial writes).
    /// C-12 note: conn.pendingResponse keeps the HTTPResponse (and its
    /// ByteBuffers) alive until the write CQE arrives. The ByteBuffer
    /// backing store is heap-allocated and stable (does not move while
    /// the buffer is alive), so the pointer passed to the SQE is valid.
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
                let ok = ringBox!.ring.prepare(request: .write(
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
                let ok = ringBox!.ring.prepare(request: .write(
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
