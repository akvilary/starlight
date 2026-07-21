//===----------------------------------------------------------------------===//
//
//  TcpListener.swift
//  StarlightServer
//
//  TCP listener with SO_REUSEPORT — port of `tokio::net::TcpListener`
//  + the `hyper::server::tcp::TcpListener` shim.
//
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
import CLinuxExt
#endif

import Foundation
import HTTP
import StarlightPoll

/// A TCP listener bound to a `(host, port)`.
///
/// Equivalent to `tokio::net::TcpListener`. The accept loop is
/// driven by an attached `PollEventLoop` — registering the listener
/// fd as a watch channel and draining `accept4(2)` when readable.
/// This is the same idiom tokio/mio use.
public final class TcpListener: @unchecked Sendable {

    /// Raw kernel fd.
    public let fd: CInt

    /// The local address this listener is bound to.
    public let host: String
    public let port: Int

    private init(fd: CInt, host: String, port: Int) {
        self.fd = fd
        self.host = host
        self.port = port
    }

    deinit {
        #if canImport(Glibc)
        _ = Glibc.close(fd)
        #endif
    }

    /// Bind a new listener. Sets `SO_REUSEADDR | SO_REUSEPORT` so
    /// multiple event loops can bind the same `(host, port)` and let
    /// the kernel load-balance incoming connections (the H2O/tokio
    /// thread-per-core pattern).
    public static func bind(host: String, port: Int) throws -> TcpListener {
        #if canImport(Glibc)
        let fd = sl_bind_listener(host, Int32(port))
        guard fd >= 0 else {
            throw ServerError.bindFailed(errno: Int32(-fd))
        }
        return TcpListener(fd: fd, host: host, port: port)
        #else
        fatalError("TcpListener.bind requires Linux (use NIOAsyncChannel on macOS)")
        #endif
    }

    /// Accept one connection. Returns the new socket fd + the peer
    /// address. Non-blocking: returns `nil` if the accept queue is
    /// empty (EAGAIN).
    ///
    /// Callers drain the queue by looping until `nil`. The accept
    /// loop's watch handler does exactly this on each readable event.
    public func accept() -> (fd: CInt, address: SocketAddress)? {
        #if canImport(Glibc)
        let fd = sl_accept4(self.fd)
        guard fd >= 0 else { return nil }
        return (fd, SocketAddress.unix(fd: fd))
        #else
        return nil
        #endif
    }
}

/// Best-effort representation of a peer socket address.
public enum SocketAddress: Sendable, Hashable {
    /// Linux: address lookup not implemented in the skeleton; the fd
    /// is preserved so the connection handler can `getpeername(2)`
    /// later when actually needed.
    case unix(fd: CInt)
}

/// Server-side errors. Mirrors `hyper::Error`'s top-level variants
/// at a coarse granularity — the skeleton does not distinguish
/// every hyper error class.
public enum ServerError: Error, Sendable, CustomStringConvertible {
    case bindFailed(errno: Int32)
    case acceptFailed(errno: Int32)
    case ioFailed(errno: Int32)
    case clientGone

    public var description: String {
        switch self {
        case .bindFailed(let e):   return "bind failed (errno \(e))"
        case .acceptFailed(let e): return "accept failed (errno \(e))"
        case .ioFailed(let e):     return "I/O failed (errno \(e))"
        case .clientGone:          return "client gone"
        }
    }
}
