//===----------------------------------------------------------------------===//
//
//  EventLoopExecutor.swift
//  StarlightCore
//
//  The central component of Starlight's thread-per-core concurrency model.
//
//  An `EventLoopExecutor` adapts a SwiftNIO `EventLoop` into a Swift Concurrency
//  `SerialExecutor & TaskExecutor`. Pinning a `Connection`-actor to one of these
//  (via `nonisolated var unownedExecutor`) means every `await` on that actor
//  stays on the same NIO event loop — no hop into the global concurrent pool,
//  no continuation allocation in the fast path. This is exactly the property
//  H2O exploits with its thread-per-core pthread-per-loop model, expressed
//  here in Swift's actor-executor vocabulary (SE-0392 + SE-0417).
//
//===----------------------------------------------------------------------===//

import NIOCore
import Synchronization

/// A Swift Concurrency executor that drives every enqueued job on a fixed
/// SwiftNIO `EventLoop`.
///
/// `EventLoopExecutor` is the adapter that lets Starlight honour the
/// thread-per-core discipline: each `Connection`-actor is bound to exactly one
/// NIO `EventLoop` (≡ one OS thread, pinned), and every `Task` or actor-method
/// invocation the connection makes runs synchronously on that loop — no
/// scheduling into the global cooperative pool, no continuation stealing.
///
/// Use `EventLoop.asTaskExecutor()` to obtain (and cache) the executor for a
/// given loop, then either:
///   - bind an actor to it via
///     `nonisolated var unownedExecutor: UnownedSerialExecutor { loop.asTaskExecutor().asUnownedSerialExecutor() }`
///   - or run a subtree of `async` work on it via
///     `withTaskExecutorPreference(loop.asTaskExecutor()) { … }`.
public final class EventLoopExecutor: SerialExecutor, TaskExecutor, @unchecked Sendable {
    /// The NIO event loop that owns this executor. Every job is enqueued onto
    /// `eventLoop.execute { … }`.
    public let eventLoop: any EventLoop

    @inlinable
    public init(_ eventLoop: any EventLoop) {
        self.eventLoop = eventLoop
    }

    // `SerialExecutor` / `TaskExecutor` conformance.
    //
    // We convert the consuming `ExecutorJob` into an `UnownedJob` *before*
    // escaping into the NIO closure — this is the lifetime-transforming move
    // the runtime expects — then re-enter the runtime on the loop with
    // `runSynchronously(isolatedTo:taskExecutor:)`, telling it both the serial
    // (isolation) executor and the task (preference) executor are this same
    // `EventLoopExecutor`. That dual identity is what suppresses hops.
    public nonisolated func enqueue(_ job: consuming ExecutorJob) {
        let unowned = UnownedJob(job)
        let serial = self.asUnownedSerialExecutor()
        let task = self.asUnownedTaskExecutor()
        let loop = self.eventLoop
        loop.execute {
            unowned.runSynchronously(isolatedTo: serial, taskExecutor: task)
        }
    }
}

//===----------------------------------------------------------------------===//
// EventLoop + Starlight extensions
//===----------------------------------------------------------------------===//

extension EventLoop {
    /// Cached `EventLoopExecutor` for this loop. Allocated once per loop and
    /// retained for the loop's lifetime (the executor itself is a single
    /// reference-counted object — amortized across every connection and every
    /// task this loop ever runs).
    ///
    /// Implementation note: the cache is keyed on `ObjectIdentifier` and
    /// guarded by a `Mutex`. It is written exactly once per loop (when the
    /// executor is first materialized) and read on every subsequent call.
    /// Because every access for a given loop comes from that loop's own
    /// thread, contention on the mutex is effectively nil.
    public func asTaskExecutor() -> EventLoopExecutor {
        return EventLoopExecutorCache.shared.executor(for: self)
    }
}

//===----------------------------------------------------------------------===//
// EventLoopExecutorCache — association of EventLoop → executor
//===----------------------------------------------------------------------===//

/// Global association from `EventLoop` identity → cached `EventLoopExecutor`.
///
/// Each `EventLoop` is a long-lived, uniquely-identified object (one per thread
/// in a `MultiThreadedEventLoopGroup`), so we use its `ObjectIdentifier` as a
/// key.
private final class EventLoopExecutorCache: @unchecked Sendable {
    static let shared = EventLoopExecutorCache()

    private let mutex = Mutex<[ObjectIdentifier: EventLoopExecutor]>([:])

    func executor(for loop: any EventLoop) -> EventLoopExecutor {
        // Fast path under the lock — the lock is uncontended in practice
        // (one writer per loop lifetime, all reads from the loop's own thread).
        self.mutex.withLock { cache in
            if let cached = cache[ObjectIdentifier(loop)] {
                return cached
            }
            let new = EventLoopExecutor(loop)
            cache[ObjectIdentifier(loop)] = new
            return new
        }
    }
}
