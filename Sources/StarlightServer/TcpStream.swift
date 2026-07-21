//===----------------------------------------------------------------------===//
//
//  TcpStream.swift
//  StarlightServer
//
//  Async TCP socket — port of `tokio::net::TcpStream`. Reads and
//  writes are driven by a `PollEventLoop` (epoll readiness).
//
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#endif

import Foundation
import HTTP
import StarlightPoll

/// An async TCP stream — the connection side of a `TcpListener::accept`.
///
/// All reads and writes go through the bound `PollEventLoop`. Each
/// `read`/`write` arms an oneshot interest, awaits the readiness
/// notification, then issues the syscall on the loop thread (which
/// is the same thread the resuming Task continues on).
public final class TcpStream: @unchecked Sendable {

    public let fd: CInt
    public let eventLoop: PollEventLoop
    public let channelId: UInt32

    /// Construct from an accepted fd. The caller must have already
    /// registered a fresh channel with `eventLoop.registerChannel()`.
    @inlinable
    public init(fd: CInt, eventLoop: PollEventLoop, channelId: UInt32) {
        self.fd = fd
        self.eventLoop = eventLoop
        self.channelId = channelId
    }

    /// Read into the buffer; returns bytes read (0 on EOF, negative
    /// on error). Uses eventLoop's internal buffer — caller accesses
    /// bytes via `eventLoop.getReadView`.
    public func read() async -> Int {
        await eventLoop.read(channelId: channelId, fd: fd)
    }

    /// Write from the buffer; returns bytes written (negative on error).
    public func write(from buffer: UnsafeRawBufferPointer) async -> Int {
        await eventLoop.write(channelId: channelId, fd: fd, from: buffer)
    }

    /// Cancel any outstanding operation on this stream and close
    /// the fd. Idempotent.
    public func close() {
        eventLoop.cancelChannel(channelId)
        #if canImport(Glibc)
        _ = Glibc.close(fd)
        #endif
    }
}
