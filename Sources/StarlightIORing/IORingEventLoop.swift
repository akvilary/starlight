//===----------------------------------------------------------------------===//
//
//  IORingEventLoop.swift
//  StarlightIORing
//
//  Generic io_uring event loop conforming to SerialExecutor.
//  Provides async read/write on any fd, cross-thread wakeup,
//  and Swift Concurrency executor semantics. Used by StarlightServer
//  (HTTP) and future drivers (Postgres, Redis, etc.).
//
//===----------------------------------------------------------------------===//

#if os(Linux) && compiler(>=6.2) && $Lifetimes

import Foundation
import SystemPackage
import CMIO
import Synchronization
import StarlightCore

#if canImport(Glibc)
import Glibc
#endif

// MARK: - IORingEventLoop

public final class IORingEventLoop: @unchecked Sendable {

    // Ring (created lazily in run() for SINGLE_ISSUER)
    private var ringBox: IORingBox?

    // Wakeup eventfd
    private var eventFd: CInt = -1
    private let wakeupBuffer: UnsafeMutableRawPointer =
        .allocate(byteCount: 8, alignment: 8)

    // Configuration
    private let queueDepth: UInt32

    // Channel tracking — unique ID per fd, prevents fd-recycling
    private var nextChannelId: UInt32 = 1  // 0 reserved for wakeup

    // Continuation bridges (loop thread only)
    private var readWaiters: [UInt32: CheckedContinuation<Int, Never>] = [:]
    private var writeWaiters: [UInt32: CheckedContinuation<Int, Never>] = [:]

    // Job queues — split by source thread
    private var loopJobs: [UnownedJob] = []
    private var poolJobs: [UnownedJob] = []
    private var jobLock = pthread_spinlock_t()
    private let loopThreadId = Atomic<UInt>(0)

    // Loop state
    private let stopped = Atomic<Bool>(false)
    private var needsSubmit = false

    // Error handling
    private var inflightSQEs: Int = 0
    private var wakeupInflight: Bool = false
    private var consecutiveErrors: Int = 0

    // Stats
    public let overflowEvents = PaddedAtomicInt64()

    // Wakeup callback — called when the loop is woken via wakeup()
    public var onWakeup: (@Sendable () -> Void)?

    // Cached executor
    private var _cachedExecutor: UnownedSerialExecutor? = nil
    public var cachedExecutor: UnownedSerialExecutor {
        if let ce = _cachedExecutor { return ce }
        let ce = UnownedSerialExecutor(ordinary: self)
        _cachedExecutor = ce
        return ce
    }

    // MARK: Init

    public init(queueDepth: UInt32 = 4096) {
        self.queueDepth = queueDepth
        pthread_spin_init(&jobLock, 0)
    }

    deinit {
        if eventFd >= 0 { Glibc.close(eventFd) }
        wakeupBuffer.deallocate()
        pthread_spin_destroy(&jobLock)
    }

    // MARK: Setup (eventfd only — ring created in run())

    private func setup() throws {
        let efd = sl_eventfd(0, LinuxSocketConst.EFD_NONBLOCK | LinuxSocketConst.EFD_CLOEXEC)
        guard efd >= 0 else {
            throw IORingError(code: Int32(errno), function: "eventfd")
        }
        eventFd = efd
    }

    // MARK: Event loop

    public func run() throws {
        loopThreadId.store(pthread_self(), ordering: .releasing)
        defer { loopThreadId.store(0, ordering: .releasing) }

        try setup()

        self.ringBox = try IORingBox(
            queueDepth: queueDepth,
            flags: [.singleSubmissionThread]
        )

        armWakeup()

        while !stopped.load(ordering: .acquiring) {
            // Phase 1: Drain CQEs from mmap memory (0 syscalls).
            var drainedAny = false
            while let cqe = ringBox!.ring.tryConsumeCompletion() {
                processCQE(cqe)
                drainedAny = true
                consecutiveErrors = 0
            }

            // Phase 2a: Submit pending SQEs.
            if needsSubmit {
                do {
                    try ringBox!.ring.submitPreparedRequests()
                    needsSubmit = false
                } catch {
                    // Submit failed — SQEs remain in SQ ring. Retry next iteration.
                }
            }

            // Phase 2b: Block only if nothing drained.
            if !drainedAny {
                do {
                    let cqe = try ringBox!.ring.blockingConsumeCompletion()
                    processCQE(cqe)
                    consecutiveErrors = 0
                } catch {
                    while let cqe = ringBox!.ring.tryConsumeCompletion() {
                        processCQE(cqe)
                        consecutiveErrors = 0
                    }
                    if inflightSQEs > 0 {
                        recoverOrphanedContinuations()
                    }
                    armWakeup()
                    consecutiveErrors += 1
                    if consecutiveErrors > 32 {
                        break
                    }
                }
            }

            // Phase 3: Drain jobs.
            drainJobs()
        }

        // Resume any remaining waiters with errors on shutdown.
        recoverOrphanedContinuations()
    }

    public func shutdown() {
        stopped.store(true, ordering: .releasing)
        wakeup()
    }

    /// True after shutdown() has been called.
    public var isStopped: Bool {
        stopped.load(ordering: .acquiring)
    }

    // MARK: CQE processing

    @inline(__always)
    private func processCQE(_ cqe: borrowing IORing.Completion) {
        inflightSQEs -= 1
        let ctx = cqe.context
        let res = cqe.result
        let op = unpackOp(ctx)

        switch op {
        case .wakeup:
            handleWakeup()
        case .recv:
            resumeRead(channelId: unpackChannelId(ctx), bytesRead: res)
        case .send:
            resumeWrite(channelId: unpackChannelId(ctx), bytesWritten: res)
        }
    }

    // MARK: Wakeup

    @inline(__always)
    private func handleWakeup() {
        wakeupInflight = false
        _ = Glibc.read(eventFd, wakeupBuffer, 8)
        armWakeup()
        onWakeup?()
    }

    @inline(__always)
    private func armWakeup() {
        guard !wakeupInflight else { return }
        let ok = ringBox!.ring.prepare(request: .read(
            FileDescriptor(rawValue: eventFd),
            into: UnsafeMutableRawBufferPointer(start: wakeupBuffer, count: 8),
            context: packUserData(channelId: 0, op: .wakeup)
        ))
        if ok { needsSubmit = true; inflightSQEs += 1; wakeupInflight = true }
    }

    /// Wake the loop from another thread. Writes to eventfd, which
    /// triggers the wakeup CQE on the loop thread.
    public func wakeup() {
        var val: UInt64 = 1
        _ = withUnsafePointer(to: &val) { ptr in
            Glibc.write(eventFd, ptr, 8)
        }
    }

    // MARK: Channel management

    /// Register a new channel. Returns a unique channelId that
    /// prevents fd-recycling misattribution. Use the returned ID
    /// with read/write/cancelChannel.
    public func registerChannel() -> UInt32 {
        let id = nextChannelId
        nextChannelId &+= 1
        return id
    }

    /// Cancel pending operations for a channel. Resumes any pending
    /// read/write continuations with -1 (error).
    public func cancelChannel(_ channelId: UInt32) {
        readWaiters.removeValue(forKey: channelId)?.resume(returning: -1)
        writeWaiters.removeValue(forKey: channelId)?.resume(returning: -1)
    }

    // MARK: Async read

    /// Async read from `fd`. Suspends until CQE arrives.
    /// Returns bytes read (0 = EOF, negative = error).
    public func read(
        channelId: UInt32, fd: CInt,
        into buffer: UnsafeMutableRawBufferPointer
    ) async -> Int {
        return await withCheckedContinuation { cont in
            if ringBox!.ring.prepare(request: .read(
                FileDescriptor(rawValue: fd),
                into: buffer,
                context: packUserData(channelId: channelId, op: .recv)
            )) {
                needsSubmit = true; inflightSQEs += 1
                readWaiters[channelId] = cont
            } else {
                cont.resume(returning: 0)
            }
        }
    }

    @inline(__always)
    private func resumeRead(channelId: UInt32, bytesRead: CInt) {
        if let cont = readWaiters.removeValue(forKey: channelId) {
            cont.resume(returning: Int(bytesRead))
        }
    }

    // MARK: Async write

    /// Async write to `fd`. Suspends until CQE arrives.
    /// Returns bytes written (negative = error).
    public func write(
        channelId: UInt32, fd: CInt,
        from buffer: UnsafeRawBufferPointer
    ) async -> Int {
        return await withCheckedContinuation { cont in
            let ptr = UnsafeMutableRawPointer(mutating: buffer.baseAddress!)
            let ok = ringBox!.ring.prepare(request: .write(
                UnsafeMutableRawBufferPointer(start: ptr, count: buffer.count),
                into: FileDescriptor(rawValue: fd),
                context: packUserData(channelId: channelId, op: .send)
            ))
            if ok { needsSubmit = true; inflightSQEs += 1; writeWaiters[channelId] = cont }
            else { cont.resume(returning: -1) }
        }
    }

    @inline(__always)
    private func resumeWrite(channelId: UInt32, bytesWritten: CInt) {
        if let cont = writeWaiters.removeValue(forKey: channelId) {
            cont.resume(returning: Int(bytesWritten))
        }
    }

    // MARK: Orphan recovery

    private func recoverOrphanedContinuations() {
        let readCount = readWaiters.count
        let writeCount = writeWaiters.count
        guard readCount > 0 || writeCount > 0 else { return }

        for (_, cont) in readWaiters { cont.resume(returning: -1) }
        readWaiters.removeAll()
        for (_, cont) in writeWaiters { cont.resume(returning: -1) }
        writeWaiters.removeAll()

        inflightSQEs -= (readCount + writeCount)
        wakeupInflight = false
        _ = overflowEvents.increment()
    }

    // MARK: Job queue

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

    private func enqueueJob(_ job: UnownedJob) {
        let tid = loopThreadId.load(ordering: .acquiring)
        if pthread_self() == tid {
            loopJobs.append(job)
        } else {
            pthread_spin_lock(&jobLock)
            poolJobs.append(job)
            let needWake = tid != 0
            pthread_spin_unlock(&jobLock)
            if needWake { wakeup() }
        }
    }
}

// MARK: - SerialExecutor conformance

extension IORingEventLoop: SerialExecutor {
    public func enqueue(_ job: consuming ExecutorJob) {
        let unowned = UnownedJob(job)
        enqueueJob(unowned)
    }

    public func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        cachedExecutor
    }

    public func isSameExclusiveExecutionContext(other: IORingEventLoop) -> Bool {
        other === self
    }
}

// MARK: - Socket constants (shared with StarlightServer)

internal enum LinuxSocketConst {
    static let EFD_NONBLOCK: Int32 = 2048
    static let EFD_CLOEXEC: Int32 = 524288
}

#endif // os(Linux) && compiler(>=6.2) && $Lifetimes
