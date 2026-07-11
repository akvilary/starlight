//===----------------------------------------------------------------------===//
//
//  LinuxSocket.swift
//  StarlightServer
//
//  Socket setup via Glibc — replaces sl_listen / sl_set_* from CStarlightLinux.
//  Only Linux. All functions are zero-allocation.
//
//===----------------------------------------------------------------------===//

#if os(Linux)

import Foundation

#if canImport(Glibc)
import Glibc
#endif

/// Socket constants not always exposed through Swift's Glibc module.
@usableFromInline
internal enum LinuxSocketConst {
    @usableFromInline static let SOCK_STREAM: Int32 = 1
    @usableFromInline static let SOCK_NONBLOCK: Int32 = 2048
    @usableFromInline static let SOCK_CLOEXEC: Int32 = 524288
    @usableFromInline static let SOL_SOCKET: Int32 = 1
    @usableFromInline static let SO_REUSEADDR: Int32 = 2
    @usableFromInline static let SO_REUSEPORT: Int32 = 15
    @usableFromInline static let SO_KEEPALIVE: Int32 = 9
    @usableFromInline static let IPPROTO_TCP: Int32 = 6
    @usableFromInline static let TCP_NODELAY: Int32 = 1
    @usableFromInline static let TCP_KEEPIDLE: Int32 = 4
    @usableFromInline static let TCP_KEEPINTVL: Int32 = 5
    @usableFromInline static let TCP_KEEPCNT: Int32 = 6
    @usableFromInline static let POLLIN: Int16 = 1
    @usableFromInline static let EFD_NONBLOCK: Int32 = 2048   // = O_NONBLOCK
    @usableFromInline static let EFD_CLOEXEC: Int32 = 524288  // = O_CLOEXEC
}

/// Create a non-blocking TCP listener with SO_REUSEADDR + SO_REUSEPORT.
/// Returns the fd ≥ 0, or negative errno on failure.
@inlinable
@discardableResult
internal func linuxCreateListener(host: String, port: Int, backlog: Int = 1024) -> CInt {
    let fd = Glibc.socket(
        AF_INET,
        LinuxSocketConst.SOCK_STREAM | LinuxSocketConst.SOCK_NONBLOCK | LinuxSocketConst.SOCK_CLOEXEC,
        0
    )
    if fd < 0 { return -errno }

    var flag: CInt = 1
    let flagSize = socklen_t(MemoryLayout<CInt>.size)

    Glibc.setsockopt(fd, LinuxSocketConst.SOL_SOCKET, LinuxSocketConst.SO_REUSEADDR, &flag, flagSize)
    Glibc.setsockopt(fd, LinuxSocketConst.SOL_SOCKET, LinuxSocketConst.SO_REUSEPORT, &flag, flagSize)

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = UInt16(port).bigEndian
    host.withCString { cstr in
        withUnsafeMutablePointer(to: &addr.sin_addr) { addrPtr in
            _ = Glibc.inet_pton(AF_INET, cstr, addrPtr)
        }
    }

    let bindResult = withUnsafePointer(to: &addr) { addrPtr in
        addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            Glibc.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    if bindResult < 0 { let e = -errno; Glibc.close(fd); return e }

    if Glibc.listen(fd, CInt(backlog)) < 0 {
        let e = -errno; Glibc.close(fd); return e
    }
    return fd
}

/// Set TCP_NODELAY on a socket. Returns 0 on success, negative errno on failure.
@inlinable
@discardableResult
internal func linuxSetTcpNoDelay(_ fd: CInt) -> CInt {
    var flag: CInt = 1
    let ret = Glibc.setsockopt(
        fd, LinuxSocketConst.IPPROTO_TCP, LinuxSocketConst.TCP_NODELAY,
        &flag, socklen_t(MemoryLayout<CInt>.size)
    )
    return ret < 0 ? -errno : 0
}

/// Enable TCP keepalive on a socket.
@inlinable
internal func linuxSetKeepalive(_ fd: CInt, idle: CInt = 60, interval: CInt = 10, count: CInt = 3) {
    var flag: CInt = 1
    var idle_v = idle
    var intv = interval
    var cnt = count
    let sz = socklen_t(MemoryLayout<CInt>.size)
    Glibc.setsockopt(fd, LinuxSocketConst.SOL_SOCKET, LinuxSocketConst.SO_KEEPALIVE, &flag, sz)
    Glibc.setsockopt(fd, LinuxSocketConst.IPPROTO_TCP, LinuxSocketConst.TCP_KEEPIDLE, &idle_v, sz)
    Glibc.setsockopt(fd, LinuxSocketConst.IPPROTO_TCP, LinuxSocketConst.TCP_KEEPINTVL, &intv, sz)
    Glibc.setsockopt(fd, LinuxSocketConst.IPPROTO_TCP, LinuxSocketConst.TCP_KEEPCNT, &cnt, sz)
}

#endif // os(Linux)
