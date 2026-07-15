//===----------------------------------------------------------------------===//
//
//  Ready.swift
//  StarlightPoll
//
//  Ready is the output counterpart of Interest — it describes which
//  readiness conditions were actually observed for a delivered event.
//  Mirrors `mio::event::Ready` (rust) minus the deprecated AIO/LIO bits
//  (unsupported on epoll).
//
//===----------------------------------------------------------------------===//

#if os(Linux)

import CLinuxExt

/// The readiness conditions observed for a delivered event.
///
/// `Ready` is what the kernel actually reports, which is a superset of
/// what was registered: an `Interest.readable` registration may surface
/// `error`, `hangup`, or `readClosed` as well. Always test these flags
/// explicitly rather than assuming only the requested bits are present.
@frozen
public struct Ready: OptionSet, Sendable, Hashable, CustomStringConvertible {
    public let rawValue: UInt32

    @inlinable
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let readable     = Ready(rawValue: 0x001)  // EPOLLIN
    public static let writable     = Ready(rawValue: 0x004)  // EPOLLOUT
    public static let priority     = Ready(rawValue: 0x002)  // EPOLLPRI
    public static let error        = Ready(rawValue: 0x008)  // EPOLLERR
    public static let hangup       = Ready(rawValue: 0x010)  // EPOLLHUP
    public static let readHangup   = Ready(rawValue: 0x2000) // EPOLLRDHUP

    /// Convenience: read-side EOF (`hangup` without `readable`, or
    /// `readHangup`). Mirrors mio's `is_read_closed`.
    public var isReadClosed: Bool {
        // EPOLLHUP alone (no EPOLLIN) ⇒ peer closed.
        // EPOLLRDHUP ⇒ peer closed the write side.
        let r = self.rawValue
        return (r & Ready.readHangup.rawValue != 0)
            || (r & Ready.hangup.rawValue != 0 && r & Ready.readable.rawValue == 0)
    }

    /// Convenience: write-side EOF (`hangup` without `writable`, or
    /// `error`). Mirrors mio's `is_write_closed`.
    public var isWriteClosed: Bool {
        let r = self.rawValue
        return (r & Ready.hangup.rawValue != 0 && r & Ready.writable.rawValue == 0)
            || (r & Ready.error.rawValue != 0)
    }

    @inlinable
    public var isReadable: Bool   { contains(.readable) }
    @inlinable
    public var isWritable: Bool   { contains(.writable) }
    @inlinable
    public var isError: Bool      { contains(.error) }
    @inlinable
    public var isHangup: Bool     { contains(.hangup) }

    public var description: String {
        var parts: [String] = []
        if isReadable { parts.append("readable") }
        if isWritable { parts.append("writable") }
        if contains(.priority) { parts.append("priority") }
        if isError { parts.append("error") }
        if isHangup { parts.append("hangup") }
        if contains(.readHangup) { parts.append("readHangup") }
        return "Ready(\(parts.joined(separator: " | ")))"
    }
}

#endif // os(Linux)
