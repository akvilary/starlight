//===----------------------------------------------------------------------===//
//
//  Interest.swift
//  StarlightPoll
//
//  Interest of a registration — what the caller wants to be notified about.
//  Mirrors `mio::Interest` (rust). Direct 1:1 mapping to epoll event bits.
//
//===----------------------------------------------------------------------===//

#if os(Linux)

import CLinuxExt

/// The set of I/O events a source is interested in being notified about.
///
/// `Interest` is an `OptionSet` over the raw 32-bit `epoll_event.events`
/// field, so callers may combine, intersect and test bits directly:
///
/// ```swift
/// let both: Interest = [.readable, .writable]
/// if both.contains(.readable) { ... }
/// ```
///
/// Two modifiers are supported in addition to the readiness bits:
///
///   - `.edge`     — adds `EPOLLET`, edge-triggered. The default is
///                   level-triggered, matching mio's portability stance.
///   - `.oneshot`  — adds `EPOLLONESHOT`. The source is auto-disabled
///                   after the first event and must be re-armed via
///                   `Registry.reregister`. This is the natural model for
///                   the async one-shot read/write API used by
///                   `PollEventLoop`.
@frozen
public struct Interest: OptionSet, Sendable, Hashable, CustomStringConvertible {
    public let rawValue: UInt32

    @inlinable
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    // ── Readiness bits ─────────────────────────────────────────────────
    //
    // These map 1:1 onto the kernel's EPOLL constants and must not be
    // renumbered.

    /// Notify when the source is readable (`EPOLLIN`).
    public static let readable = Interest(rawValue: 0x001)

    /// Notify when the source is writable (`EPOLLOUT`).
    public static let writable = Interest(rawValue: 0x004)

    /// Out-of-band / urgent data available (`EPOLLPRI`).
    public static let priority = Interest(rawValue: 0x002)

    // ── Triggering modifiers ───────────────────────────────────────────

    /// Edge-triggered. By default registrations are level-triggered.
    public static let edge = Interest(rawValue: 0x8000_0000)

    /// One-shot: deliver at most one event, then auto-disable the source
    /// until re-armed via `Registry.reregister`.
    public static let oneshot = Interest(rawValue: 0x4000_0000)

    // ── Convenience compositions ───────────────────────────────────────

    /// Both readable and writable. Convenience for `[.readable, .writable]`.
    public static let both: Interest = [.readable, .writable]

    /// Mask of the two readiness bits. Useful when stripping modifier bits
    /// before comparing or persisting.
    public static let readinessMask: Interest = [.readable, .writable, .priority]

    @inlinable
    public var isReadable: Bool { contains(.readable) }

    @inlinable
    public var isWritable: Bool { contains(.writable) }

    @inlinable
    public var isEdge: Bool { contains(.edge) }

    @inlinable
    public var isOneshot: Bool { contains(.oneshot) }

    public var description: String {
        var parts: [String] = []
        if isReadable { parts.append("readable") }
        if isWritable { parts.append("writable") }
        if contains(.priority) { parts.append("priority") }
        if isEdge { parts.append("edge") }
        if isOneshot { parts.append("oneshot") }
        return "Interest(\(parts.joined(separator: " | ")))"
    }
}

#endif // os(Linux)
