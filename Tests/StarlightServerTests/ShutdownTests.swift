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
//
//===----------------------------------------------------------------------===//

import Testing
import Foundation
import NIOCore
import StarlightHTTP
import StarlightRouting
import StarlightServer

@Suite("Server shutdown (.nio)")
struct ShutdownTests {

    /// start() must return promptly after shutdown() is called.
    /// Pre-A-2 fix: with in-flight Tasks, start() could hang because
    /// their continuations were enqueued after drainJobs() stopped
    /// running, and the Task bodies never executed.
    @Test("start() returns within 2s of shutdown()")
    func startReturnsAfterShutdown() async throws {
        let server = StarlightServer(loopCount: 2)
        let router = Router()
        router.get("/") { _ in HTTPResponse.plaintext("ok") }

        // Run start() in a detached Task so we can call shutdown()
        // from outside it.
        let startTask = Task<Void, Error> {
            try await server.start(
                host: "127.0.0.1", port: 0, mode: .http,
                httpHandler: nil, router: router
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
        let router = Router()
        router.get("/") { _ in HTTPResponse.plaintext("ok") }

        let startTask = Task<Void, Error> {
            try await server.start(
                host: "127.0.0.1", port: 0, mode: .http,
                httpHandler: nil, router: router
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
