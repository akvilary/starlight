//===----------------------------------------------------------------------===//
//
//  Waker.swift
//  StarlightPoll
//
//  Cross-thread wakeup primitive. Mirrors `mio::Waker` (rust). On Linux
//  it is implemented as an eventfd registered with EPOLLIN on the
//  target Poll; `wake()` writes 8 bytes (one wakeup), the loop observes
//  a readable event on the waker's token and drains the counter.
//
//===----------------------------------------------------------------------===//

#if os(Linux)

import Foundation
import CLinuxExt

#if canImport(Glibc)
import Glibc
#endif

/// Cross-thread wakeup primitive.
///
/// A `Waker` is bound to a specific `(Registry, Token)` pair. Calling
/// `wake()` from any thread causes that token to appear as readable on
/// the next `Poll.poll`. The loop is responsible for draining the
/// counter via `reset()` (or simply by reading 8 bytes) before waiting
/// again — otherwise level-triggered epoll will keep firing the event.
///
/// `Waker` is `Sendable` and safe to share across threads. Multiple
/// wakers may share the same token (wakeup coalescing is the kernel's
/// responsibility: eventfd's counter saturates at `UINT64_MAX - 1` and
/// a write into a full counter fails with `EAGAIN`).
public final class Waker: @unchecked Sendable {

    /// The raw eventfd. Exposed for tests.
    public let fd: CInt

    /// The token this waker raises when fired.
    public let token: Token

    private let registry: Registry

    /// Create a new waker registered for `token` on `registry`.
    ///
    /// The waker is registered with `Interest.readable` (level-triggered).
    /// The caller MUST NOT also register `fd` for any other token.
    public init(registry: Registry, token: Token) throws {
        // EFD_NONBLOCK | EFD_CLOEXEC. EFD_SEMAPHORE is NOT used — we want
        // 64-bit counter semantics so N wakeups don't require N reads.
        let fd = sl_eventfd(0, PollConstants.EFD_NONBLOCK | PollConstants.EFD_CLOEXEC)
        guard fd >= 0 else {
            throw PollError.fromErrno(function: "eventfd")
        }
        self.fd = fd
        self.token = token
        self.registry = registry
        do {
            try registry.register(fd: fd, token: token, interest: .readable)
        } catch {
            _ = Glibc.close(fd)
            throw error
        }
    }

    deinit {
        // Best-effort deregister; ignored if the caller already removed
        // the fd. Then close the eventfd.
        try? registry.deregister(fd: fd)
        _ = Glibc.close(fd)
    }

    /// Fire the waker. Adds 1 to the eventfd counter.
    ///
    /// Safe to call from any thread. Multiple wakes may coalesce; if the
    /// counter is full (saturated at `UINT64_MAX - 1`) the write fails
    /// with `EAGAIN`, which is treated as success — the waker has
    /// already been fired and not yet drained, which is exactly what
    /// the caller wanted.
    @discardableResult
    public func wake() -> Bool {
        var val: UInt64 = 1
        let n = withUnsafePointer(to: &val) { ptr -> Int in
            Glibc.write(fd, ptr, 8)
        }
        return n == 8
    }

    /// Drain pending wakeups. Should be called by the loop thread after
    /// observing the waker's token readable. A single `read` reads the
    /// entire accumulated counter and resets it to zero.
    ///
    /// On a spurious wake (counter already 0) read returns `EAGAIN`,
    /// which is silently swallowed.
    @discardableResult
    public func reset() -> UInt64 {
        var val: UInt64 = 0
        let n = withUnsafeMutablePointer(to: &val) { ptr -> Int in
            Glibc.read(fd, ptr, 8)
        }
        return n == 8 ? val : 0
    }
}

#endif // os(Linux)
