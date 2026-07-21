//===----------------------------------------------------------------------===//
//
//  ShutdownTests.swift
//  StarlightServerTests
//
//  Regression tests for A-2: shutdown path. Before the fix, event loops
//  called recoverOrphanedContinuations() without a subsequent drainJobs(),
//  leaving in-flight connection Tasks (and their captures: loop, conn,
//  codec, fds) leaked forever. drainConnections() also double-closed fds
//  because closeConnection ran Glibc.close unconditionally.
//
//  These tests exercise the corrected path:
//    1. start() returns within a bounded time after shutdown()
//    2. Repeated start/shutdown cycles do not leak (or trap)
//    3. shutdown() is idempotent
//    4. (Linux) epoll shutdown does not leak fds — P0.3 regression
//
//===----------------------------------------------------------------------===//

import Testing
import Foundation
import NIOCore
import StarlightHTTP
import StarlightRouting
@testable import StarlightServer

#if canImport(Glibc)
import Glibc
#endif

@Suite("Server shutdown (.nio)")
struct ShutdownTests {

    /// start() must return promptly after shutdown() is called.
    /// Pre-A-2 fix: with in-flight Tasks, start() could hang because
    /// their continuations were enqueued after drainJobs() stopped
    /// running, and the Task bodies never executed.
    @Test("start() returns within 2s of shutdown()")
    func startReturnsAfterShutdown() async throws {
        let server = StarlightServer(loopCount: 2)
        let builder = RouterBuilder()
        builder.get("/") { _ in HTTPResponse.plaintext("ok") }

        // Run start() in a detached Task so we can call shutdown()
        // from outside it.
        let startTask = Task<Void, Error> {
            try await server.start(
                host: "127.0.0.1", port: 0, mode: .http,
                httpHandler: nil, router: builder.build()
            )
        }

        // Give the server a moment to bind. We don't know the port
        // (port 0 = kernel-assigned), but for this test we only care
        // that start() returns after shutdown() — not that we can
        // reach it.
        try await Task.sleep(nanoseconds: 300_000_000)

        server.shutdown()

        // start() must return within 2 seconds.
        let exitTimeout = Duration.seconds(2)
        let result = try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await startTask.value }
            group.addTask {
                try await Task.sleep(for: exitTimeout)
                throw NSError(domain: "test", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "start() did not return within 2s"
                ])
            }
            let first = try await group.next()
            group.cancelAll()
            return first
        }
        #expect(result != nil)
    }

    /// shutdown() must be idempotent — calling it twice (once explicit,
    /// once from deinit) must not trap or double-resume continuations.
    @Test("shutdown() is idempotent")
    func shutdownIdempotent() async throws {
        let server = StarlightServer(loopCount: 1)
        let builder = RouterBuilder()
        builder.get("/") { _ in HTTPResponse.plaintext("ok") }

        let startTask = Task<Void, Error> {
            try await server.start(
                host: "127.0.0.1", port: 0, mode: .http,
                httpHandler: nil, router: builder.build()
            )
        }

        try await Task.sleep(nanoseconds: 300_000_000)

        server.shutdown()
        server.shutdown()   // ← must not crash
        server.shutdown()   // ← still must not crash

        // startTask should have returned by now.
        try await startTask.value
    }
}

#if os(Linux)

// MARK: - P0.3 regression: epoll shutdown fd leak

@Suite("Server shutdown (.epoll)", .serialized)
struct EpollShutdownFdLeakTests {

    /// Before the P0.3 fix, `EpollExecutorLoop.drainConnections` cancelled
    /// channels but never closed connection fds. Tasks that were not parked
    /// on `eventLoop.read`/`write` at shutdown time (e.g. an in-flight
    /// async handler, a Task spawned just before shutdown, or a Task that
    /// re-parked on I/O after the final `drainJobs()`) never reached their
    /// `closeConnection` cleanup — their fds leaked forever.
    ///
    /// The cleanest way to exercise the buggy code path is white-box:
    /// inject socketpair fds directly into `connections` and call
    /// `drainConnections`. A pre-fix build leaves the fds open
    /// (`fstat` returns 0); a post-fix build closes them (`fstat`
    /// returns -1 with errno == EBADF).
    @Test("EpollExecutorLoop.drainConnections closes injected connection fds")
    func epollDrainConnectionsClosesFds() throws {
        let loop = try EpollExecutorLoop(
            host: "127.0.0.1", port: 0, mode: .http,
            handler: { _ in HTTPResponse.plaintext("ok") },
            router: nil, stats: ServerStats(), cpuIndex: 0
        )

        // Open N socketpairs; inject the "server" end as if a real
        // connection had set it up. The "client" ends are kept open so
        // we can verify the server ends were closed (and so the kernel
        // doesn't reap the fds before our check).
        var serverFds: [CInt] = []
        var clientFds: [CInt] = []
        defer {
            for fd in clientFds where fd >= 0 { Glibc.close(fd) }
        }

        for _ in 0..<8 {
            var pair = [CInt](repeating: -1, count: 2)
            let r = Glibc.socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &pair)
            #expect(r == 0)
            serverFds.append(pair[0])
            clientFds.append(pair[1])
        }

        for fd in serverFds {
            let channelId = loop.eventLoop.registerChannel()
            loop.connections[fd] = EpollConnectionState(channelId: channelId)
        }

        // Pre-condition: the loop thinks it owns these connections.
        #expect(loop.connections.count == serverFds.count)

        loop.drainConnections()

        // Post-condition: drainConnections cleared the table.
        #expect(loop.connections.isEmpty)

        // The actual regression check: every injected server-side fd
        // must now be closed. A `read` on a closed fd returns -1 with
        // errno == EBADF.
        for fd in serverFds {
            var st = stat()
            let r = Glibc.fstat(fd, &st)
            #expect(r == -1,
                    "fd \(fd) was not closed by drainConnections (fstat returned \(r))")
        }
    }

    /// Same as the epoll test, but against `IORingExecutorLoop`. The fix
    /// is symmetric across both backends — the test should be too.
    #if compiler(>=6.2) && $Lifetimes
    @Test("IORingExecutorLoop.drainConnections closes injected connection fds")
    func ioRingDrainConnectionsClosesFds() throws {
        let loop = IORingExecutorLoop(
            host: "127.0.0.1", port: 0, mode: .http,
            handler: { _ in HTTPResponse.plaintext("ok") },
            router: nil, stats: ServerStats(), cpuIndex: 0
        )

        var serverFds: [CInt] = []
        var clientFds: [CInt] = []
        defer {
            for fd in clientFds where fd >= 0 { Glibc.close(fd) }
        }

        for _ in 0..<8 {
            var pair = [CInt](repeating: -1, count: 2)
            let r = Glibc.socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &pair)
            #expect(r == 0)
            serverFds.append(pair[0])
            clientFds.append(pair[1])
        }

        for fd in serverFds {
            let channelId = loop.eventLoop.registerChannel()
            loop.connections[fd] = IORingConnectionState(channelId: channelId)
        }

        #expect(loop.connections.count == serverFds.count)

        loop.drainConnections()

        #expect(loop.connections.isEmpty)

        for fd in serverFds {
            var st = stat()
            let r = Glibc.fstat(fd, &st)
            #expect(r == -1,
                    "fd \(fd) was not closed by drainConnections (fstat returned \(r))")
        }
    }
    #endif

    /// End-to-end smoke test: a full start/shutdown cycle with the epoll
    /// backend should not leave any fd open. Counts entries in
    /// `/proc/self/fd` across cycles — accumulating leaks surface here.
    /// A warmup cycle absorbs one-time fd setup from the test runner.
    @Test("repeated epoll start/shutdown cycles do not accumulate fds")
    func repeatedEpollShutdownDoesNotAccumulateFds() async throws {
        try await runEpollCycle()  // warmup

        let baseline = openFdCount()

        for _ in 0..<3 {
            try await runEpollCycle()
        }

        let final = openFdCount()
        #expect(final == baseline,
                "fd leak across cycles: baseline=\(baseline), final=\(final)")
    }

    private func runEpollCycle() async throws {
        let server = StarlightServer(loopCount: 1)
        let builder = RouterBuilder()
        builder.get("/") { _ in HTTPResponse.plaintext("ok") }

        let startTask = Task<Void, Error> {
            try await server.start(
                host: "127.0.0.1", port: 0, mode: .http,
                httpHandler: nil, router: builder.build(),
                linuxBackend: .epoll
            )
        }

        try await Task.sleep(nanoseconds: 500_000_000)
        server.shutdown()
        try await startTask.value

        // `shutdown()` resumes `start()` before the loop thread has
        // necessarily finished tearing down. Give it time to return
        // from `run()`, execute `drainConnections()`, release its
        // captures, and run `deinit` (which closes `listenerFd`).
        try await Task.sleep(nanoseconds: 500_000_000)
    }
}

/// Count open file descriptors for the current process by listing
/// `/proc/self/fd`. Each entry corresponds to one open fd.
private func openFdCount() -> Int {
    guard let dir = opendir("/proc/self/fd") else { return -1 }
    defer { closedir(dir) }
    var count = 0
    while readdir(dir) != nil {
        count += 1
    }
    // Subtract `.` and `..` entries that `readdir` always returns.
    return count - 2
}

#endif // os(Linux)
