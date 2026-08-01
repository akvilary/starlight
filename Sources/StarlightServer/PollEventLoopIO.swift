//===----------------------------------------------------------------------===//
//
//  PollEventLoopIO.swift
//  StarlightServer
//
//  `Http1ConnectionIO` over a pulsar `PollEventLoop` channel — the
//  bridge between the runtime-agnostic H1 codec (in HTTPCodec) and the
//  epoll reactor (in Pulsar). The analogue of hyper's tokio glue that
//  supplies `hyper::rt::Read/Write` over a tokio I/O handle.
//
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#endif

import Foundation
import Pulsar
import HTTPCodec

/// Adapts a `(PollEventLoop, fd, channelId)` triple to the codec's
/// `Http1ConnectionIO` protocol.
///
/// Created per connection (one per `driveConnection`) and handed to the
/// `H1Conn` codec. All methods run on the connection's loop thread —
/// the same thread pulsar's per-channel buffer is valid on.
struct PollEventLoopIO: Http1ConnectionIO {
    let eventLoop: PollEventLoop
    let fd: CInt
    let channelId: UInt32

    @inlinable
    func read(deadline: ContinuousClock.Instant?) async -> Int {
        await eventLoop.read(channelId: channelId, fd: fd, deadline: deadline)
    }

    @inlinable
    func readView(count: Int) -> UnsafeBufferPointer<UInt8> {
        eventLoop.getReadView(channelId: channelId, count: count)
    }

    @inlinable
    func writeRaw(_ bytes: [UInt8]) -> Int {
        // Blocking write(2) for tiny interim responses (100-Continue).
        // Called from the codec on its loop thread; the payload is
        // minute so a readiness wait is not justified — mirrors the
        // previous in-H1Conn `writeRaw` exactly (EINTR retry, stop on
        // other errors / 0).
        #if canImport(Glibc)
        return bytes.withUnsafeBufferPointer { ptr -> Int in
            var remaining = ptr.count
            var offset = 0
            while remaining > 0 {
                let n = Glibc.write(fd, ptr.baseAddress!.advanced(by: offset), remaining)
                if n > 0 {
                    remaining -= n
                    offset += n
                    continue
                }
                if n == 0 { break }
                if errno == EINTR { continue }
                break
            }
            return offset
        }
        #else
        return 0
        #endif
    }
}
