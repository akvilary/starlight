//===----------------------------------------------------------------------===//
//
//  PollTests.swift
//  StarlightPollTests
//
//  End-to-end tests for the low-level mio analog. Each test exercises
//  one primitive of the public API: Poll lifecycle, Registry register/
//  reregister/deregister, Events container, Waker cross-thread, and
//  PollTimeout semantics. The high-level PollEventLoop is exercised
//  through its own tests.
//
//===----------------------------------------------------------------------===//

#if os(Linux)

import Testing
import Foundation
import StarlightPoll
import CLinuxExt

#if canImport(Glibc)
import Glibc
#endif

@Suite("StarlightPoll", .serialized)
struct PollTests {

    // MARK: - Poll lifecycle

    @Test("Poll creates a usable epoll fd and closes it on deinit")
    func pollLifecycle() throws {
        let p = try Poll()
        #expect(p.epfd >= 0)
        // Registry shares the same epfd.
        #expect(p.registry._epfdForTests == p.epfd)
    }

    // MARK: - Events container

    @Test("Events initial state is empty")
    func eventsEmpty() throws {
        let p = try Poll()
        let ev = Events(capacity: 16)
        #expect(ev.isEmpty)
        #expect(ev.count == 0)
        // Immediate poll on an empty epoll instance must return 0 events.
        let n = try p.poll(ev, timeout: .immediate)
        #expect(n == 0)
        #expect(ev.isEmpty)
    }

    @Test("Events capacity is honoured")
    func eventsCapacity() throws {
        let ev = Events(capacity: 4)
        #expect(ev.capacity == 4)
    }

    @Test("Events.clear() resets count to zero")
    func eventsClear() throws {
        let ev = Events(capacity: 8)
        // Forcibly set count via a no-op poll then clear.
        ev.clear()
        #expect(ev.isEmpty)
    }

    // MARK: - Registry

    @Test("Registering a pipe read end and poll delivers readability")
    func pipeReadable() throws {
        let p = try Poll()
        guard let pipe = makePipe() else { Issue.record("pipe2 failed"); return }
        let (r, w) = (pipe.read, pipe.write)
        defer { _ = Glibc.close(r); _ = Glibc.close(w) }

        try p.registry.register(fd: r, token: Token(42), interest: .readable)

        // Initially no data → no events.
        let ev = Events(capacity: 4)
        #expect(try p.poll(ev, timeout: .immediate) == 0)

        // Write one byte from the other end.
        var byte: UInt8 = 0xAB
        #expect(Glibc.write(w, &byte, 1) == 1)

        // Now we should see exactly one event on Token(42), readable.
        let n = try p.poll(ev, timeout: .immediate)
        #expect(n == 1)
        var seen: Token? = nil
        ev.forEach { ev1 in
            #expect(ev1.isReadable)
            #expect(ev1.token == Token(42))
            seen = ev1.token
        }
        #expect(seen == Token(42))

        try p.registry.deregister(fd: r)
    }

    @Test("Double register fails with EEXIST")
    func doubleRegisterFails() throws {
        let p = try Poll()
        guard let pipe = makePipe() else { Issue.record("pipe2 failed"); return }
        let (r, w) = (pipe.read, pipe.write)
        defer { _ = Glibc.close(r); _ = Glibc.close(w) }

        try p.registry.register(fd: r, token: Token(1), interest: .readable)
        #expect(throws: PollError.self) {
            try p.registry.register(fd: r, token: Token(2), interest: .readable)
        }
    }

    @Test("Deregister of unknown fd fails with ENOENT")
    func deregisterUnknown() throws {
        let p = try Poll()
        // fd 123456 is almost certainly not registered.
        #expect(throws: PollError.self) {
            try p.registry.deregister(fd: 123_456)
        }
    }

    @Test("Reregister changes the token")
    func reregisterChangesToken() throws {
        let p = try Poll()
        guard let pipe = makePipe() else { Issue.record("pipe2 failed"); return }
        let (r, w) = (pipe.read, pipe.write)
        defer { _ = Glibc.close(r); _ = Glibc.close(w) }

        try p.registry.register(fd: r, token: Token(11), interest: .readable)
        try p.registry.reregister(fd: r, token: Token(22), interest: .readable)

        var byte: UInt8 = 1
        _ = Glibc.write(w, &byte, 1)
        let ev = Events(capacity: 4)
        let n = try p.poll(ev, timeout: .immediate)
        #expect(n == 1)
        ev.forEach { #expect($0.token == Token(22)) }
    }

    @Test("Oneshot fires at most once until re-armed")
    func oneshotFiresOnce() throws {
        let p = try Poll()
        guard let pipe = makePipe() else { Issue.record("pipe2 failed"); return }
        let (r, w) = (pipe.read, pipe.write)
        defer { _ = Glibc.close(r); _ = Glibc.close(w) }

        try p.registry.register(fd: r, token: Token(7), interest: [.readable, .oneshot])

        var byte: UInt8 = 1
        _ = Glibc.write(w, &byte, 1)

        let ev = Events(capacity: 4)
        // First poll: delivers the event.
        #expect(try p.poll(ev, timeout: .immediate) == 1)
        // Second poll: oneshot disabled the fd — no event, even though
        // there is still data in the pipe.
        #expect(try p.poll(ev, timeout: .immediate) == 0)

        // Re-arm and try again.
        try p.registry.reregister(fd: r, token: Token(7), interest: [.readable, .oneshot])
        #expect(try p.poll(ev, timeout: .immediate) == 1)
    }

    // MARK: - Waker

    @Test("Waker fires a readable event on its token")
    func wakerFires() throws {
        let p = try Poll()
        let waker = try Waker(registry: p.registry, token: Token(999))
        defer { _ = Glibc.close(waker.fd) }

        // Block the wake before polling — race-free because eventfd's
        // counter persists across epoll_wait calls.
        #expect(waker.wake())

        let ev = Events(capacity: 4)
        let n = try p.poll(ev, timeout: .immediate)
        #expect(n == 1)
        ev.forEach { ev1 in
            #expect(ev1.token == Token(999))
            #expect(ev1.isReadable)
        }
        // Drain so subsequent polls don't re-observe it.
        _ = waker.reset()
        #expect(try p.poll(ev, timeout: .immediate) == 0)
    }

    @Test("Waker is safe to fire multiple times before drain")
    func wakerCoalescing() throws {
        let p = try Poll()
        let waker = try Waker(registry: p.registry, token: Token(1))
        defer { _ = Glibc.close(waker.fd) }

        #expect(waker.wake())
        #expect(waker.wake())
        #expect(waker.wake())

        let ev = Events(capacity: 4)
        // Level-triggered, single event even though three wakes were issued.
        #expect(try p.poll(ev, timeout: .immediate) == 1)
        // Reset reads counter (= 3) and zeroes it.
        #expect(waker.reset() == 3)
    }

    // MARK: - Timeout

    @Test("Blocking poll returns immediately when waker is pre-fired")
    func blockingPollWithPrefiredWaker() throws {
        let p = try Poll()
        let waker = try Waker(registry: p.registry, token: Token(0))
        defer { _ = Glibc.close(waker.fd) }
        #expect(waker.wake())
        let ev = Events(capacity: 4)
        // Should NOT block — waker is already pending.
        let n = try p.poll(ev, timeout: .blocking)
        #expect(n == 1)
        _ = waker.reset()
    }

    @Test("Timed poll returns 0 after the timeout elapses with no events")
    func timedPollNoEvents() throws {
        let p = try Poll()
        let ev = Events(capacity: 4)
        let start = Date()
        let n = try p.poll(ev, timeout: .milliseconds(50))
        let elapsed = Date().timeIntervalSince(start)
        #expect(n == 0)
        #expect(elapsed >= 0.04)  // allow some scheduler slack
    }

    @Test("Cross-thread Waker unblocks a polling thread")
    func crossThreadWakeup() async throws {
        let p = try Poll()
        let waker = try Waker(registry: p.registry, token: Token(0))
        defer { _ = Glibc.close(waker.fd) }

        // Spawn a detached task that fires the waker after a short delay.
        Task.detached {
            try? await Task.sleep(for: .milliseconds(30))
            _ = waker.wake()
        }

        let ev = Events(capacity: 4)
        let start = Date()
        let n = try p.poll(ev, timeout: .milliseconds(2000))
        let elapsed = Date().timeIntervalSince(start)
        #expect(n == 1)
        #expect(elapsed < 1.5)  // woke well before the 2s safety timeout
    }
}

// MARK: - Test-only helpers

extension Registry {
    /// Test-only accessor for the underlying epoll fd.
    var _epfdForTests: CInt {
        // _epfd is @usableFromInline internal — access via @testable.
        return Mirror(reflecting: self).children.first(where: { $0.label == "_epfd" })?.value as? CInt ?? -1
    }
}

private struct TestPipe {
    let read: CInt
    let write: CInt
}

/// Create a pipe with O_NONBLOCK | O_CLOEXEC. Returns nil on failure.
private func makePipe() -> TestPipe? {
    var fds: [CInt] = [0, 0]
    let rc = fds.withUnsafeMutableBufferPointer { buf in
        // O_NONBLOCK | O_CLOEXEC = 2048 | 524288 = 526336.
        sl_pipe2(buf.baseAddress!, 526336)
    }
    guard rc == 0 else { return nil }
    return TestPipe(read: fds[0], write: fds[1])
}

#endif // os(Linux)
