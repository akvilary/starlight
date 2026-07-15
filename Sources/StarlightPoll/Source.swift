//===----------------------------------------------------------------------===//
//
//  Source.swift
//  StarlightPoll
//
//  `PollSource` protocol — the Swift equivalent of `mio::event::Source`.
//  Anything that owns an fd and wants to be polled implements it.
//  The protocol is intentionally minimal: register / reregister /
//  deregister against a `Registry`.
//
//===----------------------------------------------------------------------===//

#if os(Linux)

import CLinuxExt

/// A type that can be registered with a `Poll` for readiness events.
///
/// Equivalent to `mio::event::Source`. Conformers expose their raw fd
/// via `pollSourceFD`. `PollEventLoop` and any user-defined wrapper
/// types conform.
///
/// The protocol is `Sendable`: conformers are expected to be safe to
/// share across threads at the registration level (the underlying fd is
/// not modified by these calls).
public protocol PollSource: Sendable {
    /// The kernel file descriptor to register.
    var pollSourceFD: CInt { get }

    /// Register this source for `interest` notifications tagged with
    /// `token`. Default implementation forwards to `Registry.register`.
    func register(
        _ registry: Registry,
        token: Token,
        interest: Interest
    ) throws

    /// Update the registration. Default implementation forwards to
    /// `Registry.reregister`.
    func reregister(
        _ registry: Registry,
        token: Token,
        interest: Interest
    ) throws

    /// Remove the registration. Default implementation forwards to
    /// `Registry.deregister`.
    func deregister(_ registry: Registry) throws
}

public extension PollSource {
    func register(
        _ registry: Registry,
        token: Token,
        interest: Interest
    ) throws {
        try registry.register(fd: pollSourceFD, token: token, interest: interest)
    }

    func reregister(
        _ registry: Registry,
        token: Token,
        interest: Interest
    ) throws {
        try registry.reregister(fd: pollSourceFD, token: token, interest: interest)
    }

    func deregister(_ registry: Registry) throws {
        try registry.deregister(fd: pollSourceFD)
    }
}

#endif // os(Linux)
