//===----------------------------------------------------------------------===//
//
//  serve.swift
//  StarlightServer
//
//  `serve(host:port:service:loopCount:onShutdown:)` — direct port of
//  `axum::serve`, adapted for Swift's thread-per-core model.
//
//  axum takes a single TcpListener. We deviate: each worker binds its
//  own listener with SO_REUSEPORT, letting the kernel load-balance
//  accepts across CPUs. This is the only way to get true linear
//  scaling on multi-core under Swift's runtime model.
//
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
import CLinuxExt
#endif

import Foundation
import HTTP
import Hyper
import StarlightPoll
import StarlightTower
import Synchronization

/// Bind N worker actors to `(host, port)` and serve `service` on
/// every accepted connection. Blocks the caller until `onShutdown`
/// resolves + all in-flight requests drain (or the drain timeout
/// fires).
///
/// axum analogue:
///
/// ```swift
/// try await serve(
///     router,
///     on: "0.0.0.0", port: 8080,
///     onShutdown: { await waitForSignal() }
/// )
/// ```
///
/// `onShutdown` is an async closure. When it returns, the server:
///   1. Stops accepting new connections (per worker).
///   2. Waits up to `drainTimeout` for in-flight requests to finish.
///   3. Force-closes anything still running.
///   4. Returns to the caller.
///
/// Architecture (mirrors hyper + tokio but adapted for Swift):
///
///   • Spawns `loopCount` worker threads (one per CPU core).
///   • Each thread pins itself to its CPU via `sl_pin_to_cpu`.
///   • Each thread binds its own listener fd with SO_REUSEPORT.
///   • Each thread creates a `PollEventLoop` and a `Worker` actor
///     bound to that loop via `unownedExecutor`.
///   • Inside the worker thread, `eventLoop.run()` blocks on epoll.
///   • A monitor Task awaits `onShutdown`, then orchestrates the
///     drain across all workers.
///
public func serve<S: Service>(
    host: String = "0.0.0.0",
    port: Int = 8080,
    service: S,
    loopCount: Int = ProcessInfo.processInfo.activeProcessorCount,
    drainTimeout: Duration = .seconds(30),
    onShutdown: @escaping @Sendable () async -> Void = {
        // Default: wait forever — preserves the old "blocks until
        // killed" semantics if the caller doesn't supply a signal.
        await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
    }
) async throws where S.Request == Request<Body>, S.Response == Response<Body> {
    // Wrap the user-provided Service in a BoxService so all worker
    // actors share the same type (no per-worker generics needed).
    let router = BoxService(service)

    // Spawn `loopCount` worker threads. Each owns its own listener
    // (SO_REUSEPORT lets all of them bind the same port).
    for cpuIndex in 0..<loopCount {
        let hostCopy = host
        let portCopy = port
        let routerCopy = router
        let cpu = CInt(cpuIndex)

        let thread = Thread {
            #if canImport(Glibc)
            sl_pin_to_cpu(cpu)
            #endif

            let listenerFd: CInt
            do {
                listenerFd = try starlightBindWorkerListener(
                    host: hostCopy, port: portCopy
                )
            } catch { return }

            let eventLoop: PollEventLoop
            do {
                eventLoop = try PollEventLoop(eventsCapacity: 4096)
            } catch {
                #if canImport(Glibc)
                _ = Glibc.close(listenerFd)
                #endif
                return
            }

            let worker = Worker(
                eventLoop: eventLoop,
                listenerFd: listenerFd,
                router: routerCopy,
                cpuIndex: cpu
            )

            // Stash the worker so the serve() caller can orchestrate
            // shutdown. Race-free: workers[] is mutated only from
            // the caller's thread before any worker thread can race
            // (worker threads haven't started yet on first iteration,
            // and even when they do they don't touch workers[]).
            WorkerStash.shared.set(worker, at: cpuIndex)

            _ = try? worker.registerListenerWatchSync()

            do { try eventLoop.run() }
            catch { /* log */ }
        }
        thread.name = "starlight-worker-\(cpuIndex)"
        thread.stackSize = 1024 * 1024  // 1 MiB
        thread.start()
    }

    // Wait for all worker actors to be constructed inside their
    // threads. Cheap polling — typically completes within 1ms.
    while WorkerStash.shared.count() < loopCount {
        try? await Task.sleep(for: .milliseconds(1))
    }
    let workers = WorkerStash.shared.drain()

    // Spawn the shutdown monitor. When `onShutdown` resolves:
    //   1. Tell every worker to stop accepting new conns.
    //   2. Give in-flight conns up to `drainTimeout` to finish.
    //   3. Force-stop the loops (any remaining conns are killed).
    await onShutdown()

    for worker in workers {
        await worker.initiateShutdown()
    }

    // Drain with timeout. Each worker's waitForDrain resumes when its
    // inFlightConns hits 0; the timeout enforces a wall-clock cap.
    await withTaskGroup(of: Void.self) { g in
        for worker in workers {
            g.addTask {
                await withTimeout(drainTimeout) {
                    await worker.waitForDrain()
                }
            }
        }
    }

    // Force-close any workers that didn't drain in time. This sets
    // eventLoop.stopped = true → run() exits → thread exits.
    for worker in workers {
        worker.forceShutdown()
    }
}

// MARK: - Worker stash (cross-thread hand-off)

/// Thread-safe stash for worker actors. The worker thread creates the
/// Worker actor and needs to hand it back to the serve() caller for
/// shutdown orchestration. Backed by `Mutex` to make cross-thread
/// mutation safe under Swift 6 strict concurrency.
private final class WorkerStash: @unchecked Sendable {
    static let shared = WorkerStash()
    private var workers: [Worker?] = []
    private let lock = NSLock()

    @inline(__always)
    func set(_ worker: Worker, at index: Int) {
        lock.lock()
        defer { lock.unlock() }
        while workers.count <= index { workers.append(nil) }
        workers[index] = worker
    }

    @inline(__always)
    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return workers.compactMap { $0 }.count
    }

    @inline(__always)
    func drain() -> [Worker] {
        lock.lock()
        defer { lock.unlock() }
        let result = workers.compactMap { $0 }
        workers.removeAll()
        return result
    }
}

// MARK: - Bind helper

extension StarlightServer {
    fileprivate static func bindWorkerListener(host: String, port: Int) throws -> CInt {
        #if canImport(Glibc)
        let fd = sl_bind_listener(host, Int32(port))
        guard fd >= 0 else {
            throw ServerError.bindFailed(errno: Int32(-fd))
        }
        return fd
        #else
        fatalError("serve requires Linux (epoll backend)")
        #endif
    }
}

@inline(__always)
fileprivate func starlightBindWorkerListener(host: String, port: Int) throws -> CInt {
    try StarlightServer.bindWorkerListener(host: host, port: port)
}

fileprivate enum StarlightServer {}

// MARK: - withTimeout helper (Void variant)

/// Run `operation`, racing it against a sleep. If the sleep fires
/// first, the operation is cancelled (its continuation stays parked
/// forever — we don't actually need to resume it; the caller moves on).
@inline(__always)
fileprivate func withTimeout(
    _ timeout: Duration,
    _ operation: @escaping @Sendable () async -> Void
) async {
    await withTaskGroup(of: Void.self) { g in
        g.addTask { await operation() }
        g.addTask {
            try? await Task.sleep(for: timeout)
        }
        // Wait for whichever fires first, then cancel the other.
        _ = await g.next()
        g.cancelAll()
    }
}
