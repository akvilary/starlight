//===----------------------------------------------------------------------===//
//
//  PollEventLoop.swift
//  StarlightPoll
//
//  High-level Swift Concurrency event loop built on top of the low-level
//  `Poll` / `Registry` / `Waker` primitives from the `mio` package
//  (https://github.com/akvilary/mio). This is the epoll analogue of
//  `StarlightIORing.IORingEventLoop` — same async `read`/`write`
//  surface, same SerialExecutor semantics, but every operation is
//  driven by readiness notifications on a single epoll fd instead of
//  io_uring submissions.
//
//  The mio primitives are re-exported, so `import StarlightPoll` is
//  sufficient to reach `Poll`, `Token`, `Interest`, `Ready`, etc.
//
//  Design notes
//  ------------
//  * Each channel uses EPOLLONESHOT. When a Task awaits `read`, the loop
//    arms `[.readable, .oneshot]`; when the kernel reports the fd ready,
//    the loop performs the actual `read(2)` on the loop thread (same
//    thread that will resume the Task) and resumes the continuation with
//    the byte count — mirroring io_uring's "kernel does the read" model
//    without the kernel-side buffer registration cost.
//  * The loop's `run()` blocks on `epoll_wait` and only returns control
//    to `drainJobs()` between waits, so a single thread drives I/O and
//    Task progress. This is the same thread-per-core model used by the
//    io_uring backend.
//  * Cross-thread wakeup is via `Waker` (eventfd). Cross-thread Task
//    enqueue uses the same spinlock-protected pool as IORingEventLoop.
//
//===----------------------------------------------------------------------===//

#if os(Linux)

import Foundation
// Direct `import MIO` (not `@_exported`) — the re-export attribute
// conflicts with `~Copyable` type extension visibility in current
// Swift 6.2 toolchains: methods declared on a `~Copyable` struct
// disappear from the re-exporter's view even though they appear in
// the module interface. The re-export is moved to a dedicated file
// `ReexportMIO.swift` that contains nothing else, so the bulk of
// this module sees MIO through the plain `import` below.
import MIO
import Synchronization
import StarlightCore

#if canImport(Glibc)
import Glibc
#endif

// MARK: - ChannelState

/// Per-channel pending-op state. Held by the loop, mutated only on the
/// loop thread (with the exception of `cancelChannel`, which is
/// expected to be called from the loop thread as well — it is the
/// connection-loop task that does this).
///
/// A channel is in exactly one of two modes:
///   - **managed**: `watch == nil`. The loop performs the actual
///     `read(2)`/`write(2)` when the fd is ready and resumes the
///     pending continuation. One `EPOLLONESHOT` event per armed op,
///     re-armed by `rearm`.
///   - **watch**: `watch != nil`. The loop does no I/O itself — it calls
///     `watch` with the observed `Ready` and returns. The fd stays armed
///     with the caller-supplied interest (typically level-triggered and
///     persistent, e.g. a listening socket drained with `accept4`).
@usableFromInline
internal struct PollChannelState {
    var fd: CInt
    var registered: Bool = false
    var pendingRead: CheckedContinuation<Int, Never>?
    var pendingWrite: (CheckedContinuation<Int, Never>, UnsafeRawBufferPointer)?
    var watch: (@Sendable (Ready) -> Void)?
    /// Per-channel read buffer — pre-allocated, reused across
    /// keep-alive requests. Owned by the eventLoop (NOT by the
    /// decoder). Eliminates @unchecked on H1Decoder + ConnState.
    var readBuffer: UnsafeMutablePointer<UInt8>?
    var readCapacity: Int = 8192
}

// MARK: - PollEventLoop

/// Async event loop driven by epoll.
///
/// Equivalent to `StarlightIORing.IORingEventLoop` but backed by
/// `Poll`/`Registry`. Conforms to `SerialExecutor` (SE-0392) so that
/// Swift Concurrency Tasks can be pinned to a single loop thread — the
/// thread-per-core model used throughout Starlight.
public final class PollEventLoop: @unchecked Sendable {

    // Epoll primitives.
    public let poll: Poll
    public let registry: Registry
    // `Events` is now a `~Copyable` struct — single-owner, single-thread.
    // Stored as `var` because `Poll.poll` requires `inout` access (it
    // writes the delivered-event count). The compiler now rejects any
    // accidental aliasing or cross-thread sharing that `@unchecked
    // Sendable` on the previous class form silently permitted.
    private var events: Events
    private var waker: Waker?

    // Per-channel pending-op tracking — loop thread only.
    //
    // INVARIANT: `PollChannelState` is a value type — any code path that
    // reads a state from this dict, mutates the local copy, and resumes
    // continuations MUST persist the mutated copy back via
    // `channels[channelId] = state` before returning. `rearm(state:)`
    // does NOT read from this dict and does NOT persist its own
    // mutations; the caller owns the single write-back after rearm.
    private var nextChannelId: UInt32 = 1
    private var channels: [UInt32: PollChannelState] = [:]

    // Cross-thread job queue (SerialExecutor surface).
    private var loopJobs: [UnownedJob] = []
    private var poolJobs: [UnownedJob] = []
    private var jobLock = pthread_spinlock_t()
    private let loopThreadId = Atomic<UInt>(0)

    // Loop state.
    private let stopped = Atomic<Bool>(false)
    private var consecutiveErrors: Int = 0

    // Stats.
    public let overflowEvents = PaddedAtomicInt64()

    // User hook invoked from the loop thread after the waker fires.
    public var onWakeup: (@Sendable () -> Void)?

    // Cached UnownedSerialExecutor (created on first access).
    private var _cachedExecutor: UnownedSerialExecutor? = nil
    public var cachedExecutor: UnownedSerialExecutor {
        if let ce = _cachedExecutor { return ce }
        let ce = UnownedSerialExecutor(ordinary: self)
        _cachedExecutor = ce
        return ce
    }

    // Cached UnownedTaskExecutor (created on first access).
    // Used by `Task(executorPreference: loop)` — the runtime fetches
    // this once per Task spawn, so caching avoids a fresh
    // `UnownedTaskExecutor` struct allocation on each enqueue.
    private var _cachedTaskExecutor: UnownedTaskExecutor? = nil
    public var cachedTaskExecutor: UnownedTaskExecutor {
        if let te = _cachedTaskExecutor { return te }
        let te = UnownedTaskExecutor(ordinary: self)
        _cachedTaskExecutor = te
        return te
    }

    // MARK: Init

    public init(eventsCapacity: Int = 1024) throws {
        self.poll = try Poll()
        self.registry = poll.registry
        self.events = Events(capacity: eventsCapacity)
        pthread_spin_init(&jobLock, 0)
    }

    deinit {
        if let w = waker { _ = Glibc.close(w.fd) }
        pthread_spin_destroy(&jobLock)
    }

    // MARK: Event loop

    public func run() throws {
        loopThreadId.store(UInt(pthread_self()), ordering: .releasing)
        defer { loopThreadId.store(0, ordering: .releasing) }

        // Register the cross-thread waker on the loop thread.
        self.waker = try Waker(registry: registry, token: .wakeup)

        while !stopped.load(ordering: .acquiring) {
            // Phase 1: block on epoll_wait until at least one source is
            // ready (or the waker fires, or a signal interrupts).
            do {
                try self.events.wait(on: self.poll, timeout: PollTimeout.blocking)
                consecutiveErrors = 0
            } catch {
                // Recoverable errors: log, sleep briefly, retry. After 32
                // consecutive failures give up — same threshold as the
                // io_uring backend.
                consecutiveErrors += 1
                if consecutiveErrors > 32 { throw error }
                continue
            }

            // Phase 2: dispatch each event. Channel reads/writes run the
            // actual syscall here so the resumed Task sees the result.
            events.forEach { event in
                if event.token == .wakeup {
                    handleWakeup()
                } else {
                    processChannelEvent(event)
                }
            }

            // Phase 3: drain queued jobs (connection Tasks resuming, new
            // Tasks, etc.). Jobs enqueue themselves via `enqueue` which
            // may have been called by Task.runSynchronously in phase 2
            // (a Task awaiting `read` whose body queued another op) or
            // by another thread.
            drainJobs()
        }

        // Resume any remaining waiters with errors on shutdown.
        // Then drain the resulting jobs: each resume enqueues a Task
        // continuation into loopJobs/poolJobs. Without this final
        // drain, the Tasks (which hold captures of the loop, connection
        // fds, codecs, etc.) would leak — their cleanup code (which
        // calls closeConnection and returns) never runs.
        recoverOrphanedContinuations()
        drainJobs()
    }

    public func shutdown() {
        stopped.store(true, ordering: .releasing)
        wakeup()
    }

    /// True after `shutdown()` has been called.
    public var isStopped: Bool {
        stopped.load(ordering: .acquiring)
    }

    // MARK: Wakeup

    @inline(__always)
    private func handleWakeup() {
        _ = waker?.reset()
        onWakeup?()
    }

    /// Wake the loop from any thread. The next `poll()` iteration will
    /// observe the wakeup token and invoke `onWakeup`.
    public func wakeup() {
        _ = waker?.wake()
    }

    // MARK: Channel management

    /// Allocate a fresh, unique channelId. Use the returned id with
    /// `read`/`write`/`cancelChannel`. The id is never reused, which
    /// prevents fd-recycling misattribution. Allocates a per-channel
    /// read buffer (8KB, reused across keep-alive requests).
    public func registerChannel() -> UInt32 {
        let id = nextChannelId
        nextChannelId &+= 1
        var state = PollChannelState(fd: -1)
        state.readBuffer = .allocate(capacity: state.readCapacity)
        channels[id] = state
        return id
    }

    /// Register a watch channel — an fd the caller wants to drive
    /// directly via `handler` rather than through the async read/write
    /// API. Returns a fresh channelId that can later be passed to
    /// `cancelChannel`.
    ///
    /// The canonical use case is a listening socket: register it with
    /// `.readable` (level-triggered, no `.oneshot`) and drain
    /// `accept4(2)` in `handler` until `EAGAIN`. The loop does no I/O on
    /// a watch channel and does not re-arm it — `handler` is invoked for
    /// every readiness event the kernel reports, matching mio's plain
    /// level-triggered registration.
    ///
    /// `handler` runs on the loop thread. It is stored (escaping) for the
    /// lifetime of the channel; allocate it once at setup, not per event.
    public func registerWatch(
        fd: CInt, interest: Interest,
        _ handler: @Sendable @escaping (Ready) -> Void
    ) throws -> UInt32 {
        let id = nextChannelId
        nextChannelId &+= 1
        var state = PollChannelState(fd: fd)
        state.watch = handler
        try registry.register(fd: fd, token: Token(id), interest: interest)
        state.registered = true
        channels[id] = state
        return id
    }

    /// Cancel any outstanding read/write on `channelId`. Pending
    /// continuations are resumed with `-1`. Should be called on the
    /// loop thread (typically from the connection-loop Task body).
    /// Also valid for a watch channel: its handler closure is released
    /// when the entry is removed.
    public func cancelChannel(_ channelId: UInt32) {
        guard let state = channels.removeValue(forKey: channelId) else { return }
        if let cont = state.pendingRead  { cont.resume(returning: -1) }
        if let (cont, _) = state.pendingWrite { cont.resume(returning: -1) }
        if state.registered { try? registry.deregister(fd: state.fd) }
        // Free per-channel read buffer.
        if let buf = state.readBuffer { buf.deallocate() }
    }

    // MARK: Async read

    /// Await readability on `(channelId, fd)`, then read into the
    /// eventLoop's internal per-channel buffer. Returns bytes read
    /// (0 on EOF, negative on error).
    ///
    /// The buffer is owned by the eventLoop — callers access it via
    /// `getReadView(channelId:count:)` after this returns. This
    /// eliminates the need for the caller to own a raw buffer (and
    /// thus the need for @unchecked Sendable on decoder/conn types).
    public func read(channelId: UInt32, fd: CInt) async -> Int {
        return await withCheckedContinuation { cont in
            armRead(channelId: channelId, fd: fd, cont: cont)
        }
    }

    /// Get a view into the per-channel read buffer after `read()`
    /// returns. The pointer is valid until the next `read()` call
    /// on the same channel. Called from the loop thread only.
    public func getReadView(channelId: UInt32, count: Int) -> UnsafeBufferPointer<UInt8> {
        guard let state = channels[channelId], let buf = state.readBuffer else {
            return UnsafeBufferPointer(start: nil, count: 0)
        }
        return UnsafeBufferPointer(start: buf, count: Swift.min(count, state.readCapacity))
    }

    @inline(__always)
    private func armRead(
        channelId: UInt32, fd: CInt,
        cont: CheckedContinuation<Int, Never>
    ) {
        var state = channels[channelId] ?? PollChannelState(fd: fd)
        state.fd = fd
        precondition(state.pendingRead == nil,
            "PollEventLoop: overlapping read on channelId=\(channelId)")
        state.pendingRead = cont
        rearm(channelId: channelId, state: &state)
        channels[channelId] = state
    }

    // MARK: Async write

    /// Await writability on `(channelId, fd)`, then perform a single
    /// `write(2)` from `buffer`. Returns bytes written (negative on
    /// error).
    ///
    /// - Precondition: the caller MUST ensure no other `write` is
    ///   in flight on the same `channelId`. See `read()` for the
    ///   rationale — the same invariant applies symmetrically here.
    public func write(
        channelId: UInt32, fd: CInt,
        from buffer: UnsafeRawBufferPointer
    ) async -> Int {
        return await withCheckedContinuation { cont in
            armWrite(channelId: channelId, fd: fd, cont: cont, buffer: buffer)
        }
    }

    @inline(__always)
    private func armWrite(
        channelId: UInt32, fd: CInt,
        cont: CheckedContinuation<Int, Never>,
        buffer: UnsafeRawBufferPointer
    ) {
        var state = channels[channelId] ?? PollChannelState(fd: fd)
        state.fd = fd
        precondition(state.pendingWrite == nil,
            "PollEventLoop: overlapping write on channelId=\(channelId) — previous continuation would leak")
        state.pendingWrite = (cont, buffer)
        rearm(channelId: channelId, state: &state)
        // Single write-back after rearm (see armRead for rationale).
        channels[channelId] = state
    }

    // MARK: Re-arm logic

    /// Recompute the interest mask for the channel based on currently
    /// pending ops, then ADD or MOD the fd. Called after each op is
    /// armed and after each event is processed.
    @inline(__always)
    private func rearm(channelId: UInt32, state: inout PollChannelState) {
        var interest: Interest = []
        if state.pendingRead != nil  { interest.insert(.readable) }
        if state.pendingWrite != nil { interest.insert(.writable) }

        // If nothing is pending, deregister to free the epoll slot —
        // otherwise the kernel keeps a dangling interest entry.
        guard !interest.isEmpty else {
            if state.registered {
                try? registry.deregister(fd: state.fd)
                state.registered = false
            }
            return
        }

        // Always one-shot: we want exactly one event per armed op, then
        // the loop decides what to do next.
        interest.insert(.oneshot)

        do {
            if state.registered {
                try registry.reregister(
                    fd: state.fd, token: Token(channelId), interest: interest
                )
            } else {
                try registry.register(
                    fd: state.fd, token: Token(channelId), interest: interest
                )
                state.registered = true
            }
        } catch {
            // EBADF / ENOMEM / ENOMEM: surface as immediate error to the
            // caller(s) by resuming with -1. The channels dict stays
            // consistent.
            if let cont = state.pendingRead {
                state.pendingRead = nil
                cont.resume(returning: -1)
            }
            if let (cont, _) = state.pendingWrite {
                state.pendingWrite = nil
                cont.resume(returning: -1)
            }
        }
    }

    // MARK: Channel-event processing

    @inline(__always)
    private func processChannelEvent(_ event: Event) {
        let channelId = UInt32(truncatingIfNeeded: event.token.raw)
        guard var state = channels[channelId] else { return }

        // Watch channels: the caller owns I/O. Invoke the handler and
        // return without touching the read/write continuation path or
        // re-arming — the fd stays armed with its caller-supplied
        // interest (typically level-triggered + persistent). No write-
        // back needed: `state` is unmodified here.
        if let watch = state.watch {
            watch(event.ready)
            return
        }

        let fd = state.fd

        // Read readiness: issue read(2) into internal buffer, resume waiter.
        if event.isReadable, let cont = state.pendingRead {
            state.pendingRead = nil
            let n = Glibc.read(fd, state.readBuffer!, state.readCapacity)
            cont.resume(returning: Int(n))
        }

        // Write readiness: issue write(2) and resume the waiter.
        if event.isWritable, let (cont, buf) = state.pendingWrite {
            state.pendingWrite = nil
            let n = Glibc.write(fd, buf.baseAddress!, buf.count)
            cont.resume(returning: Int(n))
        }

        // Error / EOF handling. EPOLLHUP-without-IN is read-side EOF,
        // surfaced as a 0-byte read (mirrors io_uring recv on a closed
        // socket). EPOLLERR surfaces as -1 to any remaining waiter.
        if event.ready.isError {
            if let cont = state.pendingRead {
                state.pendingRead = nil
                cont.resume(returning: -1)
            }
            if let (cont, _) = state.pendingWrite {
                state.pendingWrite = nil
                cont.resume(returning: -1)
            }
        } else if event.ready.isReadClosed,
                  let cont = state.pendingRead {
            // Peer closed write side (EPOLLRDHUP) or hung up without
            // data: deliver EOF.
            state.pendingRead = nil
            cont.resume(returning: 0)
        }

        // Re-arm with whatever is still pending. If both directions
        // were satisfied, this deregisters. Single write-back after
        // rearm (see armRead for rationale).
        rearm(channelId: channelId, state: &state)
        channels[channelId] = state
    }

    // MARK: Orphan recovery

    private func recoverOrphanedContinuations() {
        for (_, var state) in channels {
            if let cont = state.pendingRead {
                state.pendingRead = nil
                cont.resume(returning: -1)
            }
            if let (cont, _) = state.pendingWrite {
                state.pendingWrite = nil
                cont.resume(returning: -1)
            }
        }
        // Releases any held watch closures (e.g. the listener's accept
        // handler) as well as the channel states.
        channels.removeAll()
        _ = overflowEvents.increment()
    }

    // MARK: Job queue (SerialExecutor)

    /// Drain all queued jobs until both queues are empty.
    ///
    /// MUST be a `while` loop (not a single-pass snapshot) because
    /// running a job can enqueue more jobs — most notably the body
    /// of a freshly-spawned `Task { ... }` is enqueued as a separate
    /// job after the Task's setup job runs. A single-pass drain would
    /// leave the body job in `loopJobs` until the next drainJobs()
    /// call (after the next poll.poll() round-trip), which with
    /// blocking epoll_wait means "forever".
    private func drainJobs() {
        while true {
            var jobs = loopJobs
            loopJobs.removeAll(keepingCapacity: true)

            if !poolJobs.isEmpty {
                pthread_spin_lock(&jobLock)
                jobs.append(contentsOf: poolJobs)
                poolJobs.removeAll(keepingCapacity: true)
                pthread_spin_unlock(&jobLock)
            }
            if jobs.isEmpty { return }
            if jobs.count > 1 {
            }

            for job in jobs {
                job.runSynchronously(on: cachedExecutor)
            }
        }
    }

    private func enqueueJob(_ job: UnownedJob) {
        let tid = loopThreadId.load(ordering: .acquiring)
        let cur = UInt(pthread_self())
        if cur == tid {
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

extension PollEventLoop: SerialExecutor {
    public func enqueue(_ job: consuming ExecutorJob) {
        let unowned = UnownedJob(job)
        enqueueJob(unowned)
    }

    public func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        cachedExecutor
    }

    /// Verify we're on the loop thread. Used by `Actor.assumeIsolated`
    /// to check isolation when an actor's `unownedExecutor` returns
    /// this loop.
    ///
    /// The default `SerialExecutor` implementation checks the current
    /// Task's executor — which fails when the call site is a sync
    /// context (e.g., inside `run()`'s watch callback). For our
    /// thread-per-core model, "executing on this loop" means
    /// "executing on the loop's OS thread" — verifiable via
    /// `pthread_self()` against the stored `loopThreadId`.
    public func checkIsolated() {
        let expected = loopThreadId.load(ordering: .acquiring)
        let current = UInt(pthread_self())
        if current != expected {
            fatalError(
                "PollEventLoop isolation violation: current thread \(current) is not the loop thread \(expected)"
            )
        }
    }

    public func isSameExclusiveExecutionContext(other: PollEventLoop) -> Bool {
        other === self
    }
}

// MARK: - TaskExecutor conformance
//
// `TaskExecutor` (SE-0431, macOS 15+/iOS 18+) lets us spawn a Task
// pinned to this executor directly via:
//
//     Task(executorPreference: loop.eventLoop) {
//         // runs on the loop's thread
//     }
//
// Without this, the only way to pin a Task to a custom executor was
// to route it through an actor with a `nonisolated unownedExecutor`
// property — that's why EpollConnectionActor existed as an empty
// singleton. With TaskExecutor, the actor wrapper is no longer
// necessary; Tasks can be spawned directly against the loop.
//
// The implementation is trivial because `enqueue` semantics are
// identical to SerialExecutor — the difference is only the API
// surface (Task(executorPreference:) vs. await on actor method).
extension PollEventLoop: TaskExecutor {
    public func asUnownedTaskExecutor() -> UnownedTaskExecutor {
        return cachedTaskExecutor
    }
}

#endif // os(Linux)
