//===----------------------------------------------------------------------===//
//
//  Token.swift
//  StarlightPoll
//
//  User-supplied identifier returned by the kernel alongside an event.
//  Mirrors `mio::Token` (rust). On epoll it is carried in the 64-bit
//  `data` field of `struct epoll_event`.
//
//===----------------------------------------------------------------------===//

#if os(Linux)

import CLinuxExt

/// A user-supplied identifier associated with a registered I/O source.
///
/// `Token` is opaque to the poll loop: the kernel stores it as a `UInt64`
/// when the source is registered and returns it unchanged when the source
/// becomes ready. The caller is responsible for choosing values that
/// uniquely identify a connection across its lifetime.
///
/// Conventional values:
///   - `Token(0)` is typically the wakeup token (paired with `Waker`).
///   - For connection-oriented servers, prefer a monotonically increasing
///     id rather than a raw fd — this avoids the fd-recycling misattribution
///     race that exists whenever a closed fd is reopened by an unrelated
///     `socket()` before the previous owner is deregistered.
@frozen
public struct Token: Hashable, Sendable, CustomStringConvertible {
    /// The raw value carried in `epoll_event.data.u64`.
    public let raw: UInt64

    @inlinable
    public init(_ raw: UInt64) { self.raw = raw }

    /// Convenience: construct from any `FixedWidthInteger` (e.g. an
    /// incrementing `UInt32` channelId).
    @inlinable
    public init<T: BinaryInteger>(_ id: T) { self.raw = UInt64(id) }

    @inlinable
    public var description: String { "Token(\(raw))" }
}

extension Token {
    /// Reserved token for the loop-internal wakeup channel.
    /// Callers MUST NOT register a source with this value.
    public static let wakeup = Token(0)
}

#endif // os(Linux)
