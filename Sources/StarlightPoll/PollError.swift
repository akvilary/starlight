//===----------------------------------------------------------------------===//
//
//  PollError.swift
//  StarlightPoll
//
//  Error surface of the poll module. Mirrors `std::io::Error` as exposed
//  by mio (rust): a raw errno plus the failing syscall name.
//
//===----------------------------------------------------------------------===//

#if os(Linux)

import Foundation

#if canImport(Glibc)
import Glibc
#endif

/// An error raised by a `Poll`/`Registry`/`Waker` operation.
///
/// Carries the raw `errno` value and the name of the failing syscall so
/// that production logs are self-explanatory without consulting the
/// source. `code` is the raw errno value (`Int32`) — never the negated
/// form used internally by the C wrappers.
public struct PollError: Error, Sendable, CustomStringConvertible, Equatable {
    /// Raw errno value (positive, matching the C `errno` convention).
    public let code: Int32
    /// Name of the failing syscall (e.g. "epoll_wait", "eventfd").
    public let function: String

    @inlinable
    public init(code: Int32, function: String) {
        self.code = code
        self.function = function
    }

    /// Construct from the thread-local `errno`. Captures `errno` at call
    /// time — the caller is responsible for not letting any intervening
    /// syscall clobber it.
    public static func fromErrno(function: String) -> PollError {
        return PollError(code: Int32(errno), function: function)
    }

    public var description: String {
        // strerror is not async-signal-safe but is fine on a normal Swift
        // call path. Buffer-copy via Swift String to avoid any lifetime
        // issues with the static buffer.
        let msg = String(cString: strerror(code))
        return "PollError(\(function)): \(msg) [errno \(code)]"
    }
}

#endif // os(Linux)
