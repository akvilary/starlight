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
import Synchronization
import HTTP
import HTTPCodec
import Pulsar
import HTTPPrism
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
public func serve<S: HTTPService>(
    host: String = "0.0.0.0",
    port: Int = 8080,
    service: S,
    loopCount: Int = ProcessInfo.processInfo.activeProcessorCount,
    drainTimeout: Duration = .seconds(30),
    onShutdown: @escaping @Sendable () async -> Void = {
        // B5 FIX: install signal handlers by default so Ctrl-C / kill
        // always triggers graceful shutdown — matching axum's default
        // behaviour where the server responds to SIGINT/SIGTERM without
        // any explicit user setup.
        installShutdownSignalHandlers()
        await waitForShutdownSignal()
    }
) async throws {
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

    // Drain all workers in parallel, with a global wall-clock cap.
    //
    // A timer Task sleeps for drainTimeout; if it fires before the
    // drain completes, it force-shuts-down every worker's event loop.
    // The cascade (loop exit → recoverOrphanedContinuations → conn
    // close → inFlightConns → 0 → drainContinuation.resume) causes
    // waitForDrain to return for each worker.
    //
    // If the drain completes naturally first, the timer is cancelled.
    // After cancellation, `try?` swallows the CancellationError and
    // execution continues to forceShutdown — which is always called
    // regardless (matching the previous code's unconditional
    // forceShutdown after drain).
    let timer = Task {
        try? await Task.sleep(for: drainTimeout)
        for worker in workers { worker.forceShutdown() }
    }

    await withTaskGroup(of: Void.self) { g in
        for worker in workers {
            g.addTask { await worker.waitForDrain() }
        }
    }

    timer.cancel()
}

// MARK: - Worker stash (cross-thread hand-off)

/// Thread-safe stash for worker actors. The worker thread creates the
/// Worker actor and needs to hand it back to the serve() caller for
/// shutdown orchestration. Backed by `Mutex` — Sendable without
/// @unchecked.
private final class WorkerStash: Sendable {
    static let shared = WorkerStash()
    private let workers = Mutex<[Worker?]>([])

    @inline(__always)
    func set(_ worker: Worker, at index: Int) {
        workers.withLock { arr in
            while arr.count <= index { arr.append(nil) }
            arr[index] = worker
        }
    }

    @inline(__always)
    func count() -> Int {
        workers.withLock { $0.compactMap { $0 }.count }
    }

    @inline(__always)
    func drain() -> [Worker] {
        workers.withLock { arr in
            let result = arr.compactMap { $0 }
            arr.removeAll()
            return result
        }
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
