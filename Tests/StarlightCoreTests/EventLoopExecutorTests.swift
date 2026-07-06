//===----------------------------------------------------------------------===//
//
//  EventLoopExecutorTests.swift
//  StarlightCoreTests
//
//  Smoke tests for EventLoopExecutor. Verifies that work scheduled via
//  `withTaskExecutorPreference(loop.asTaskExecutor())` actually runs on the
//  pinned loop's thread (thread-per-core promise), and that the executor is
//  cached per loop.
//
//===----------------------------------------------------------------------===//

import Foundation
import NIOCore
import NIOPosix
import Testing
@testable import StarlightCore

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

@Suite("EventLoopExecutor")
struct EventLoopExecutorTests {
    @Test("Work under withTaskExecutorPreference runs on the pinned loop's thread")
    func actorPinnedToLoop() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { Task { try? await group.shutdownGracefully() } }

        let targetLoop = group.next()
        let executor = targetLoop.asTaskExecutor()

        // Capture the *test's* pthread identity outside any async context
        // — `Thread.current` is unavailable from async functions in Swift
        // 6.2. `pthread_self` is available everywhere.
        let testPthread = pthread_self()

        // Run a closure on the pinned executor. Inside it, capture the
        // *running* pthread identity and return it.
        let observedPthread = await withTaskExecutorPreference(executor) {
            pthread_self()
        }

        // The pinned executor runs its jobs on `targetLoop`'s thread, which
        // is *some* NIO thread, not the test's thread. The two pthread
        // identities must therefore differ.
        #expect(pthread_equal(observedPthread, testPthread) == 0)
    }

    @Test("Executor is cached per EventLoop")
    func executorIsCached() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }

        let loop = group.next()
        let a = loop.asTaskExecutor()
        let b = loop.asTaskExecutor()

        // Same EventLoop → same cached executor instance.
        #expect(a === b)
        // The executor's loop is the one we asked for.
        #expect(a.eventLoop === loop)
    }
}
