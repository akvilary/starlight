//===----------------------------------------------------------------------===//
//
//  serve.swift
//  StarlightServer
//
//  `serve(host:port:service:loopCount:)` — direct port of `axum::serve`,
//  adapted for Swift's thread-per-core model.
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

/// Bind N worker actors to `(host, port)` and serve `service` on
/// every accepted connection. Blocks the caller until shutdown.
///
/// Architecture (mirrors hyper + tokio but adapted for Swift):
///
///   • Spawns `loopCount` worker threads (one per CPU core).
///   • Each thread pins itself to its CPU via `sl_pin_to_cpu`.
///   • Each thread binds its own listener fd with SO_REUSEPORT —
///     the kernel load-balances incoming accepts across workers
///     via a hash of the source IP/port. No thundering herd.
///   • Each thread creates a `PollEventLoop` and a `Worker` actor
///     bound to that loop via `unownedExecutor`.
///   • Inside the worker Task, `eventLoop.run()` blocks on epoll.
///
/// Task spawn cost per connection: **zero**. Task spawn cost per
/// request: one short-lived child Task (for async handler dispatch).
///
public func serve<S: Service>(
    host: String = "0.0.0.0",
    port: Int = 8080,
    service: S,
    loopCount: Int = ProcessInfo.processInfo.activeProcessorCount
) async throws where S.Request == Request<Body>, S.Response == Response<Body> {
    // Wrap the user-provided Service in a BoxService so all worker
    // actors share the same type (no per-worker generics needed).
    let router = BoxService(service)

    // Spawn `loopCount` worker threads. Each owns its own listener
    // (SO_REUSEPORT lets all of them bind the same port — kernel
    // distributes accepts across them).
    var workerThreads: [Thread] = []
    for cpuIndex in 0..<loopCount {
        let hostCopy = host
        let portCopy = port
        let routerCopy = router
        let cpu = CInt(cpuIndex)

        let thread = Thread {
            #if canImport(Glibc)
            // Pin this OS thread to its CPU before anything else —
            // every allocation, syscall, and Task hop below runs on
            // this core for the lifetime of the worker.
            sl_pin_to_cpu(cpu)
            #endif

            // Bind this worker's own listener. SO_REUSEPORT is set
            // inside sl_bind_listener so multiple workers can bind
            // the same (host, port).
            let listenerFd: CInt
            do {
                listenerFd = try starlightBindWorkerListener(
                    host: hostCopy, port: portCopy
                )
            } catch {
                // Bind failure is fatal for this worker — log and exit.
                // (Other workers may succeed if the failure is transient.)
                return
            }

            // Each worker thread runs one Task that drives its
            // eventLoop. The Task lives for the lifetime of the
            // server — no per-connection Tasks.
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

            // CRITICAL: register the listener watch BEFORE starting
            // the loop. Otherwise the first poll blocks forever
            // waiting for an event that has no handler registered.
            // Sync call (nonisolated on Worker).
            _ = try? worker.registerListenerWatchSync()

            // Run the loop. Blocks this thread until shutdown.
            // This is what drives all I/O + actor dispatch for this
            // worker — calling epoll_wait, dispatching events to
            // watch callbacks, and draining the job queue (which is
            // how actor method calls like writeResponse execute).
            do { try eventLoop.run() }
            catch { /* log */ }
        }
        thread.name = "starlight-worker-\(cpuIndex)"
        thread.stackSize = 1024 * 1024  // 1 MiB
        thread.start()
        workerThreads.append(thread)
    }

    // Suspend the caller until shutdown. (Phase-2: signal handler.)
    await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in
        // Skeleton: hang forever. Real shutdown wiring lands with
        // signal handling.
    }
}

extension StarlightServer {
    /// Bind a fresh listener fd with SO_REUSEADDR | SO_REUSEPORT.
    /// Each worker calls this — the kernel load-balances accepts
    /// across all bound sockets.
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

/// Top-level alias matching axum-style usage.
@inline(__always)
fileprivate func starlightBindWorkerListener(host: String, port: Int) throws -> CInt {
    try StarlightServer.bindWorkerListener(host: host, port: port)
}

/// Phantom type used only to host the static helper above.
fileprivate enum StarlightServer {}
