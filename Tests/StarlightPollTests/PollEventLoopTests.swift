//===----------------------------------------------------------------------===//
//
//  PollEventLoopTests.swift
//  StarlightPollTests
//
//  End-to-end tests for the async event loop surface. Each test spawns
//  the loop on a dedicated thread, performs async read/write against
//  in-process sockets/pipes, and verifies that the same contract as
//  `IORingEventLoop` is upheld.
//
//===----------------------------------------------------------------------===//

#if os(Linux)

import Testing
import Foundation
import Synchronization
import StarlightPoll

#if canImport(Glibc)
import Glibc
#endif

@Suite("PollEventLoop", .serialized)
struct PollEventLoopTests {

    // A minimal actor pinned to the loop's SerialExecutor — mirrors the
    // pattern in `StarlightServer`'s ConnectionActor. Required because
    // Swift 6.2 has no `Task(executor:)` overload for `SerialExecutor`
    // (only for `TaskExecutor`); the canonical way to drive Tasks on a
    // custom serial executor is via an actor whose
    // `nonisolated unownedExecutor` returns it.
    actor LoopPinned {
        nonisolated let _executor: UnownedSerialExecutor
        init(_ executor: UnownedSerialExecutor) { self._executor = executor }
        nonisolated var unownedExecutor: UnownedSerialExecutor { _executor }

        /// Allocate, read, copy out, deallocate — all inside the actor
        /// so no `UnsafeMutableRawBufferPointer` crosses actor
        /// boundaries (StrictMemorySafety).
        func runRead(loop: PollEventLoop, channelId: UInt32,
                     fd: CInt, capacity: Int) async -> (Int, [UInt8]) {
            let buf = UnsafeMutableRawBufferPointer.allocate(
                byteCount: capacity, alignment: 8)
            defer { buf.deallocate() }
            let n = await loop.read(channelId: channelId, fd: fd, into: buf)
            var out = [UInt8](repeating: 0, count: max(0, n))
            for i in 0..<out.count {
                out[i] = buf.load(fromByteOffset: i, as: UInt8.self)
            }
            return (n, out)
        }

        /// Drive one write followed by one read on the same socket
        /// pair. Sequential — the loop processes one Task at a time
        /// per iteration (mirrors IORingEventLoop's echoLoop pattern;
        /// `async let` would deadlock because child tasks queued during
        /// drainJobs don't run until the next poll() returns).
        func runRoundTrip(loop: PollEventLoop,
                          writerCh: UInt32, readerCh: UInt32,
                          a: CInt, b: CInt,
                          payload: [UInt8]) async -> (writeN: Int, readN: Int, read: [UInt8]) {
            let writeBuf = UnsafeMutableRawBufferPointer.allocate(
                byteCount: payload.count, alignment: 8)
            defer { writeBuf.deallocate() }
            payload.withUnsafeBufferPointer { src in
                writeBuf.copyMemory(from: UnsafeRawBufferPointer(src))
            }
            let readBuf = UnsafeMutableRawBufferPointer.allocate(
                byteCount: 8, alignment: 8)
            defer { readBuf.deallocate() }

            // Write first, then read — both on the loop thread.
            let writeN = await loop.write(
                channelId: writerCh, fd: a,
                from: UnsafeRawBufferPointer(writeBuf))
            let readN = await loop.read(
                channelId: readerCh, fd: b, into: readBuf)

            var out = [UInt8](repeating: 0, count: max(0, readN))
            for i in 0..<out.count {
                out[i] = readBuf.load(fromByteOffset: i, as: UInt8.self)
            }
            return (writeN, readN, out)
        }
    }

    // MARK: - Echo over a socketpair

    @Test("Async read over socketpair delivers bytes")
    func readSocketpair() async throws {
        let loop = try PollEventLoop()
        let sp = makeSocketpair()
        guard let sp else { Issue.record("socketpair failed"); return }
        let (a, b) = (sp.read, sp.write)
        defer {
            _ = Glibc.close(a); _ = Glibc.close(b)
            loop.shutdown()
        }

        // Run the loop on a dedicated OS thread.
        let loopThread = Thread { [loop] in
            try? loop.run()
        }
        loopThread.start()
        try await Task.sleep(for: .milliseconds(30))

        let channelId = loop.registerChannel()

        let payload: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        _ = payload.withUnsafeBufferPointer { ptr in
            Glibc.write(a, ptr.baseAddress!, 4)
        }

        // Drive the read primitive from an actor pinned to the loop so
        // the read mutates loop-private state from the loop thread.
        let pinned = LoopPinned(loop.cachedExecutor)
        let (n, out) = await pinned.runRead(
            loop: loop, channelId: channelId, fd: b, capacity: 8)

        #expect(n == 4)
        #expect(out.count >= 4)
        #expect(out[0] == 0xDE)
        #expect(out[3] == 0xEF)
    }

    @Test("Wakeup callback fires from another thread")
    func wakeupFromAnotherThread() async throws {
        let loop = try PollEventLoop()

        let fired = Atomic<Bool>(false)
        loop.onWakeup = { fired.store(true, ordering: .releasing) }

        let loopThread = Thread { [loop] in
            try? loop.run()
        }
        loopThread.start()
        try await Task.sleep(for: .milliseconds(30))

        // Wake from this thread.
        loop.wakeup()

        // Give the loop a moment to process.
        try await Task.sleep(for: .milliseconds(40))
        #expect(fired.load(ordering: .acquiring) == true)

        loop.shutdown()
    }

    @Test("Async write then read round-trips through the loop")
    func writeReadRoundTrip() async throws {
        let loop = try PollEventLoop()
        let sp = makeSocketpair()
        guard let sp else { Issue.record("socketpair failed"); return }
        let (a, b) = (sp.read, sp.write)
        defer {
            _ = Glibc.close(a); _ = Glibc.close(b)
            loop.shutdown()
        }

        let loopThread = Thread { [loop] in try? loop.run() }
        loopThread.start()
        try await Task.sleep(for: .milliseconds(30))

        let writerCh = loop.registerChannel()
        let readerCh = loop.registerChannel()

        let payload: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06]

        let pinned = LoopPinned(loop.cachedExecutor)
        let result = await pinned.runRoundTrip(
            loop: loop, writerCh: writerCh, readerCh: readerCh,
            a: a, b: b, payload: payload
        )

        #expect(result.writeN == 6)
        #expect(result.readN == 6)
        #expect(Array(result.read.prefix(6)) == payload)
    }

    @Test("Watch channel fires its handler on the loop thread")
    func watchReadiness() async throws {
        let loop = try PollEventLoop()
        let sp = makeSocketpair()
        guard let sp else { Issue.record("socketpair failed"); return }
        let (a, b) = (sp.read, sp.write)
        defer {
            _ = Glibc.close(a); _ = Glibc.close(b)
            loop.shutdown()
        }

        let fired = Atomic<Bool>(false)
        let readyBits = Atomic<UInt32>(0)

        // Register end `a` as a watch BEFORE starting the loop — this
        // matches production usage (registerWatch is called from run()
        // before eventLoop.run()) and avoids a race on the loop-private
        // `channels` map.
        _ = try loop.registerWatch(fd: a, interest: .readable) { ready in
            readyBits.store(ready.rawValue, ordering: .releasing)
            fired.store(true, ordering: .releasing)
        }

        let loopThread = Thread { [loop] in try? loop.run() }
        loopThread.start()
        try await Task.sleep(for: .milliseconds(30))

        // Write to the other end → `a` becomes readable.
        var byte: UInt8 = 0x55
        _ = withUnsafePointer(to: &byte) { ptr in
            Glibc.write(b, ptr, 1)
        }

        try await Task.sleep(for: .milliseconds(40))
        #expect(fired.load(ordering: .acquiring) == true)
        let bits = readyBits.load(ordering: .acquiring)
        #expect(Ready(rawValue: bits).isReadable)
    }
}

// MARK: - Helpers

private struct TestPipe {
    let read: CInt
    let write: CInt
}

private func makeSocketpair() -> TestPipe? {
    var fds: [CInt] = [0, 0]
    let rc = fds.withUnsafeMutableBufferPointer { buf in
        // SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC = 1 | 2048 | 524288
        Glibc.socketpair(AF_UNIX, 1 | 2048 | 524288, 0, buf.baseAddress!)
    }
    return rc == 0 ? TestPipe(read: fds[0], write: fds[1]) : nil
}

#endif // os(Linux)
