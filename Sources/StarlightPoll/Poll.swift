//===----------------------------------------------------------------------===//
//
//  Poll.swift / Registry.swift
//  StarlightPoll
//
//  Low-level mio analog. `Poll` owns the epoll fd; `Registry` is a
//  shareable handle exposing only the registration surface. Mirrors
//  `mio::{Poll, Registry}` (rust).
//
//===----------------------------------------------------------------------===//

#if os(Linux)

import Foundation
import CLinuxExt

#if canImport(Glibc)
import Glibc
#endif

/// Timeout argument for `Poll.poll`. Maps cleanly onto the `int timeout`
/// argument of `epoll_wait(2)`:
///
///   - `.blocking`        → -1 (block indefinitely)
///   - `.immediate`       →  0 (non-blocking poll, return immediately)
///   - `.milliseconds(n)` →  n (block up to n ms)
@frozen
public struct PollTimeout: Sendable, Hashable {
    public let rawMilliseconds: CInt

    @inlinable
    internal init(raw: CInt) { self.rawMilliseconds = raw }

    public static let blocking   = PollTimeout(raw: -1)
    public static let immediate  = PollTimeout(raw: 0)

    public static func milliseconds(_ ms: Int) -> PollTimeout {
        // Clamp to epoll_wait's int range. Negative values are reserved
        // for "block forever" — anything < -1 is undefined behaviour.
        let clamped = max(0, CInt(ms))
        return PollTimeout(raw: clamped)
    }

    public static func milliseconds(_ ms: CInt) -> PollTimeout {
        return milliseconds(Int(max(0, ms)))
    }
}

/// Top-level epoll handle.
///
/// A `Poll` owns a single epoll fd (created via `epoll_create1` with
/// `EPOLL_CLOEXEC`). Sources are registered through `registry`; events
/// are awaited through `poll`.
///
/// Threading model: the `Poll`/`Registry` pair is `Sendable`. `Registry`
/// may be cloned freely and used from any thread. The same epoll fd may
/// be concurrently read via `poll` (from one thread) and modified via
/// `register`/`reregister`/`deregister` (from any thread) — this is
/// explicitly permitted by epoll(7). The realistic pattern is one
/// thread per `Poll`, with cross-thread registration as needed.
public final class Poll: @unchecked Sendable {

    /// Raw epoll fd. Used by integration tests; production code should
    /// go through `Registry`.
    public let epfd: CInt

    /// The registry associated with this poll instance.
    public let registry: Registry

    public init() throws {
        let fd = sl_epoll_create1()
        // sl_epoll_create1 returns -errno on failure.
        guard fd >= 0 else {
            throw PollError.fromErrno(function: "epoll_create1")
        }
        self.epfd = fd
        self.registry = Registry(epfd: fd)
    }

    deinit {
        if epfd >= 0 { _ = Glibc.close(epfd) }
    }

    /// Wait for registered sources to become ready and write up to
    /// `events.capacity` events into `events`.
    ///
    /// On return, `events.count` reflects the number of delivered events
    /// (0 on timeout). Previous contents of `events` are overwritten.
    ///
    /// `EINTR` is retried automatically — callers never see it. All other
    /// errors are surfaced as `PollError`.
    @discardableResult
    public func poll(
        _ events: Events,
        timeout: PollTimeout = .blocking
    ) throws -> Int {
        // Note: `events` is a reference type; the new count is observable
        // to the caller without `inout`.
        while true {
            let n = sl_epoll_wait(
                epfd,
                events._rawBuffer,
                CInt(events.capacity),
                timeout.rawMilliseconds
            )
            if n >= 0 {
                events._setDeliveredCount(Int(n))
                return Int(n)
            }
            // n < 0 ⇒ the C wrapper has already folded errno into the
            // return value as -errno.
            let err = -n
            if err == EINTR {
                // Interrupted by a signal — retry. The caller's effective
                // timeout may be shortened by the time spent blocked
                // before the signal; for an event loop that retries
                // immediately this is the correct behaviour. Callers
                // needing precise timeout accounting should use
                // `.immediate` and their own clock.
                continue
            }
            events._setDeliveredCount(0)
            throw PollError(code: Int32(err), function: "epoll_wait")
        }
    }
}

/// A handle to a `Poll` exposing only source registration.
///
/// `Registry` is `Equatable` (two registries are equal iff they reference
/// the same underlying epoll fd) and `Hashable`. It may be shared across
/// threads.
public final class Registry: @unchecked Sendable, Hashable {
    @usableFromInline internal let _epfd: CInt

    @usableFromInline internal init(epfd: CInt) {
        self._epfd = epfd
    }

    /// Register `fd` for notifications described by `interest`, tagging
    /// it with `token`. The token is returned verbatim in any subsequent
    /// `Event`.
    ///
    /// The fd must not already be registered with this epoll instance
    /// (`EEXIST` is raised as `PollError`). The fd must be a valid kernel
    /// file descriptor — `epoll_ctl(2)` rejects fds referring to a
    /// different epoll instance, but accepts any non-epoll fd.
    public func register(
        fd: CInt, token: Token, interest: Interest
    ) throws {
        let rc = sl_epoll_ctl_add(_epfd, fd, interest.rawValue, token.raw)
        if rc != 0 {
            throw PollError(code: Int32(-rc), function: "epoll_ctl(ADD)")
        }
    }

    /// Re-register `fd` with a new `token`/`interest`. Used to re-arm
    /// oneshot sources after an event, or to change interest bits on a
    /// live registration.
    public func reregister(
        fd: CInt, token: Token, interest: Interest
    ) throws {
        let rc = sl_epoll_ctl_mod(_epfd, fd, interest.rawValue, token.raw)
        if rc != 0 {
            throw PollError(code: Int32(-rc), function: "epoll_ctl(MOD)")
        }
    }

    /// Remove `fd` from this epoll instance. Idempotent at the kernel
    /// level only if the fd is registered; calling `deregister` on a
    /// never-registered fd returns `ENOENT`, surfaced as `PollError`.
    public func deregister(fd: CInt) throws {
        let rc = sl_epoll_ctl_del(_epfd, fd)
        if rc != 0 {
            throw PollError(code: Int32(-rc), function: "epoll_ctl(DEL)")
        }
    }

    // ── Hashable / Equatable — by underlying epfd ──────────────────────

    public static func == (lhs: Registry, rhs: Registry) -> Bool {
        lhs._epfd == rhs._epfd
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(_epfd)
    }
}

#endif // os(Linux)
