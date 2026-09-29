//===----------------------------------------------------------------------===//
//
//  Upgrade.swift
//  StarlightServer
//
//  Protocol-upgrade tunneling (RFC 9110 §15.2.2 / WebSocket-style
//  handshakes): a handler sets `UpgradeHandoff` on a 101 response;
//  after the response is flushed, the connection driver hands the
//  raw channel to the handler's tunnel closure and stops speaking
//  HTTP on it.
//
//  Lifecycle: the connection Task owns the channel for the whole
//  tunnel session. The handler reads/writes via `UpgradedConnection`
//  and RETURNS when the tunnel is done (or failed) — the driver then
//  tears the channel down exactly once. There is deliberately no
//  `close()` on the tunnel handle: a single teardown owner means no
//  double-close and no leaked channel.
//
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#endif

import Foundation
import Pulsar

/// A 101 Switching Protocols connection, handed to the upgrade
/// handler. HTTP framing has ended — this is raw byte I/O over the
/// upgraded channel.
public struct UpgradedConnection: Sendable {
    let eventLoop: PollEventLoop
    let fd: CInt
    let channelId: ChannelId

    /// Bytes the client sent after the upgrade request but before
    /// they could be consumed by HTTP framing (clients routinely
    /// send the first protocol frames immediately). Deliver these to
    /// the protocol before reading from the channel.
    public let initialBytes: [UInt8]

    /// Read the next chunk of protocol bytes from the upgraded
    /// channel.
    ///
    /// - Returns: the bytes read, or `nil` on EOF / I/O failure /
    ///   timeout (a tunnel cannot do anything useful with errno
    ///   distinctions — treat nil as "the tunnel is over" and
    ///   return).
    public func read(timeout: Duration = .seconds(30)) async -> [UInt8]? {
        let n = await eventLoop.read(
            channelId: channelId,
            deadline: ContinuousClock.now + timeout
        )
        guard n > 0 else { return nil }
        let view = eventLoop.getReadView(channelId: channelId, count: n)
        return Array(view)
    }

    /// Write protocol bytes to the upgraded channel with
    /// reactor-backed backpressure (optimistic write; `EPOLLOUT`
    /// await on EAGAIN — the same discipline the HTTP write path
    /// uses).
    ///
    /// - Returns: `true` iff every byte was written; `false` on
    ///   error, hangup, or stall past `timeout` (treat as "the
    ///   tunnel is over" and return).
    public func write(
        _ bytes: [UInt8],
        timeout: Duration = .seconds(30)
    ) async -> Bool {
        #if canImport(Glibc)
        var offset = 0
        let count = bytes.count
        while offset < count {
            let n: Int = bytes.withUnsafeBytes { rb in
                Int(Glibc.write(
                    fd, rb.baseAddress!.advanced(by: offset),
                    count - offset
                ))
            }
            if n > 0 { offset += n; continue }
            if n == 0 { return false }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                let deadline = ContinuousClock.now + timeout
                if !(await eventLoop.awaitWritable(
                    channelId: channelId, deadline: deadline
                )) {
                    return false
                }
                continue
            }
            return false  // EPIPE / EBADF / ...
        }
        return true
        #else
        return false
        #endif
    }
}

/// Set by a handler on a 101 Switching Protocols response to take
/// over the connection as a raw byte tunnel.
///
/// ```swift
/// var response = Response(status: StatusCode(101))
/// response.headers.insert(.connection, "upgrade")
/// response.headers.insert(.upgrade, "websocket")
/// response.extensions.insert(UpgradeHandoff { conn in
///     _ = await conn.write(conn.initialBytes)  // then the protocol loop
/// })
/// ```
///
/// The closure runs on the connection's event-loop Task. When it
/// returns, the channel is torn down (that is the tunnel's only
/// shutdown path — there is no `close()` to forget).
public struct UpgradeHandoff: Sendable {
    public let handler: @Sendable (UpgradedConnection) async -> Void

    public init(onUpgrade: @escaping @Sendable (UpgradedConnection) async -> Void) {
        self.handler = onUpgrade
    }
}
