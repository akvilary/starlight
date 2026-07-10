//===----------------------------------------------------------------------===//
//
//  IOUringLoop.swift
//  StarlightServer
//
//  Per-thread io_uring event loop — Linux only.
//
//  Architecture (one loop per CPU core, dedicated Thread):
//
//    ┌─── io_uring thread (this file) ───────────────────────┐
//    │                                                        │
//    │  sl_wait_cqe → [CQE batch]                            │
//    │    ├─ ACCEPT CQE → accept4 → TCP_NODELAY → RECV SQE   │
//    │    ├─ RECV CQE   → feed codec → tryParseSync          │
//    │    │                .response → SEND SQE immediately  │
//    │    │                .needsAsync → Task + semaphore    │
//    │    │                .incomplete → RECV SQE             │
//    │    ├─ SEND CQE   → keep-alive? RECV : close           │
//    │    └─ POLL CQE   → drain async response queue         │
//    │                                                        │
//    └────────────────────────────────────────────────────────┘
//
//===----------------------------------------------------------------------===//

#if os(Linux)

import Foundation
import CStarlightLinux
import NIOCore
import StarlightCore
import StarlightHTTP
import StarlightRouting

#if canImport(Glibc)
import Glibc
#endif
import Dispatch

// MARK: - user_data packing

internal enum IouringOp: UInt64 {
    case accept = 1
    case recv   = 2
    case send   = 3
    case poll   = 4
}

@inline(__always)
internal func packUserData(fd: CInt, op: IouringOp) -> UInt64 {
    UInt64(UInt32(bitPattern: fd)) | (op.rawValue << 32)
}

@inline(__always)
internal func unpackFD(_ data: UInt64) -> CInt {
    CInt(bitPattern: UInt32(truncatingIfNeeded: data))
}

@inline(__always)
internal func unpackOp(_ data: UInt64) -> IouringOp {
    IouringOp(rawValue: data >> 32) ?? .accept
}

// MARK: - IOUringLoop

final class IOUringLoop: @unchecked Sendable {

    private var ring = sl_ring()
    private var listenerFd: CInt = -1
    private var wakeupFd: CInt = -1  // eventfd

    private let host: String
    private let port: Int
    private let handler: HTTPHandler?
    private let router: Router?
    private let ringEntries: UInt32 = 512
    private let readBufferSize: Int = 8192
    internal let loopStats: ServerStats

    /// fd → pre-allocated read buffer
    private var readBuffers: [CInt: UnsafeMutablePointer<UInt8>] = [:]
    /// fd → send buffer (kept alive until SEND CQE)
    private var sendBuffers: [CInt: [UInt8]] = [:]
    /// fd → bytes already sent (for partial write tracking)
    private var sendOffsets: [CInt: Int] = [:]
    /// fd → keep-alive flag for pending send
    private var sendKeepAlive: [CInt: Bool] = [:]
    /// fd → codec
    private var codecs: [CInt: HTTP1Codec] = [:]

    /// Async response queue (thread-safe — pool threads write, loop reads)
    private var responseQueue: [(fd: CInt, data: [UInt8], keepAlive: Bool)] = []
    private var responseLock = pthread_mutex_t()

    private var stopped = false

    init(host: String, port: Int, handler: HTTPHandler?, router: Router?, stats: ServerStats) {
        self.host = host
        self.port = port
        self.handler = handler
        self.router = router
        self.loopStats = stats
        pthread_mutex_init(&responseLock, nil)
    }

    deinit {
        pthread_mutex_destroy(&responseLock)
        for (_, buf) in readBuffers { buf.deallocate() }
        if ring.ring_fd >= 0 { sl_ring_exit(&ring) }
        if listenerFd >= 0 { close(listenerFd) }
        if wakeupFd >= 0 { close(wakeupFd) }
    }

    // MARK: - Setup

    func setup() throws {
        let ret = sl_ring_init(&ring, ringEntries)
        guard ret == 0 else {
            throw StarlightIOError(code: Int32(ret), function: "sl_ring_init")
        }
        let lfd = host.withCString { ptr in
            sl_listen(ptr, Int32(port), Int32(1024))
        }
        guard lfd >= 0 else {
            throw StarlightIOError(code: Int32(-lfd), function: "sl_listen")
        }
        listenerFd = lfd

        let efd = eventfd(0, 2048 | 524288)  // EFD_NONBLOCK | EFD_CLOEXEC
        guard efd >= 0 else {
            throw StarlightIOError(code: Int32(errno), function: "eventfd")
        }
        wakeupFd = efd

        try submitAccept()
        try submitWakeupPoll()
        _ = sl_submit(&ring)
    }

    // MARK: - Event loop

    func run() throws {
        while !stopped {
            var cqe: UnsafeMutablePointer<io_uring_cqe>? = nil
            let ret = sl_wait_cqe(&ring, &cqe)

            if ret < 0 {
                if -ret == EINTR || -ret == EAGAIN { continue }
                throw StarlightIOError(code: Int32(ret), function: "sl_wait_cqe")
            }
            guard let first = cqe else { continue }

            // Process all available CQEs (batch)
            var current: UnsafeMutablePointer<io_uring_cqe>? = first
            while current != nil {
                processCQE(current!)
                sl_cqe_seen(&ring)
                let n = sl_peek_cqe(&ring, &current)
                if n == 0 { break }
            }

            drainResponseQueue()
        }
        sl_ring_exit(&ring)
    }

    // MARK: - CQE dispatch

    private func processCQE(_ cqe: UnsafeMutablePointer<io_uring_cqe>) {
        let data = sl_cqe_data(cqe)
        let res = cqe.pointee.res
        let op = unpackOp(data)

        switch op {
        case .accept: handleAccept(res: res)
        case .recv:   handleRecv(fd: unpackFD(data), bytesRead: res)
        case .send:   handleSend(fd: unpackFD(data), bytesWritten: res)
        case .poll:   handleWakeup()
        }
    }

    // MARK: - Accept

    private func submitAccept() throws {
        guard let sqe = sl_get_sqe(&ring) else { return }
        sl_prep_accept(sqe, listenerFd)
        sl_sqe_set_data(sqe, packUserData(fd: listenerFd, op: .accept))
    }

    private func handleAccept(res: CInt) {
        // POLL_ADD completed on listener — drain all pending connections.
        while true {
            let fd = sl_accept4(listenerFd)
            if fd < 0 { break }

            _ = sl_set_tcp_nodelay(fd)
            _ = loopStats.connectionsAccepted.increment()

            let readBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: readBufferSize)
            readBuffers[fd] = readBuf

            if let router = router {
                codecs[fd] = HTTP1Codec(router: router)
            } else if let handler = handler {
                codecs[fd] = HTTP1Codec(handler: handler)
            }

            submitRecv(fd: fd, buf: readBuf)
        }
        try? submitAccept()
    }

    // MARK: - Recv

    private func submitRecv(fd: CInt, buf: UnsafeMutablePointer<UInt8>) {
        guard let sqe = sl_get_sqe(&ring) else { return }
        sl_prep_recv(sqe, fd, buf, UInt32(readBufferSize))
        sl_sqe_set_data(sqe, packUserData(fd: fd, op: .recv))
        _ = sl_submit(&ring)
    }

    private func handleRecv(fd: CInt, bytesRead: CInt) {
        guard bytesRead > 0 else {
            closeConnection(fd: fd)
            return
        }

        _ = loopStats.bytesReceived.add(Int64(bytesRead))

        guard let readBuf = readBuffers[fd],
              let codec = codecs[fd] else {
            closeConnection(fd: fd)
            return
        }

        // Feed bytes to codec
        var buf = ByteBufferAllocator().buffer(capacity: Int(bytesRead))
        buf.writeBytes(UnsafeBufferPointer(start: readBuf, count: Int(bytesRead)))
        codec.feed(buf)

        // Parse + dispatch (handles pipelining)
        processRequests(fd: fd, codec: codec, readBuf: readBuf)
    }

    /// Process as many pipelined requests as the codec has buffered.
    /// For each response: submit SEND SQE. When incomplete: re-arm RECV.
    private func processRequests(fd: CInt, codec: HTTP1Codec,
                                  readBuf: UnsafeMutablePointer<UInt8>) {
        while true {
            let result = codec.tryParseSync()

            switch result {
            case .incomplete:
                submitRecv(fd: fd, buf: readBuf)
                return

            case .response(let response):
                submitSend(fd: fd, response: response)
                return  // RECV re-armed after SEND completes

            case .needsAsync:
                // Phase 1: async handlers not supported in io_uring path.
                // The eventfd + response queue infrastructure is in place
                // for Phase 2. Sync handlers (the benchmark case) never
                // hit this path.
                let r = HTTPResponse.plaintext(
                    "500 Async handlers require NIO backend\n",
                    status: .internalServerError,
                    keepAlive: false
                )
                codec.afterDispatch()
                submitSend(fd: fd, response: r)
                return
            }
        }
    }

    // MARK: - Send

    private func submitSend(fd: CInt, response: HTTPResponse) {
        // Copy response bytes into a [UInt8] that we own. This array
        // stays alive in sendBuffers[fd] until the SEND CQE arrives,
        // ensuring the pointer passed to io_uring remains valid.
        //
        // The copy is unavoidable for safety: the HTTPResponse's
        // ByteBuffer backing storage might be shared (COW) and could
        // be modified by another connection. We need exclusive
        // ownership of the bytes until the kernel finishes reading them.
        var bytes = Array(response.headerBuffer.readableBytesView)
        if let body = response.bodyBuffer {
            bytes.append(contentsOf: body.readableBytesView)
        }

        _ = loopStats.bytesSent.add(Int64(bytes.count))

        sendBuffers[fd] = bytes
        sendKeepAlive[fd] = response.keepAlive
        sendOffsets[fd] = 0  // bytes already sent (for partial write tracking)

        guard let sqe = sl_get_sqe(&ring) else { return }
        // Use sendBuffers[fd] (not the local `bytes`) as the pointer
        // source — it's the stable copy that outlives this function.
        sendBuffers[fd]!.withUnsafeBufferPointer { ptr in
            sl_prep_send(sqe, fd, ptr.baseAddress!, UInt32(ptr.count))
        }
        sl_sqe_set_data(sqe, packUserData(fd: fd, op: .send))
        _ = sl_submit(&ring)  // flush immediately — don't wait for next loop iteration
    }

    private func handleSend(fd: CInt, bytesWritten: CInt) {
        // Handle errors: connection reset, broken pipe, etc.
        if bytesWritten < 0 {
            closeConnection(fd: fd)
            return
        }

        // Partial write handling: the kernel may have accepted fewer
        // bytes than we submitted (e.g., socket send buffer full on
        // a slow client). We must send the remaining bytes.
        let offset = sendOffsets[fd] ?? 0
        let totalLen = sendBuffers[fd]?.count ?? 0
        let newOffset = offset + Int(bytesWritten)

        if newOffset < totalLen {
            // More bytes to send — submit another SEND SQE for the
            // remaining portion of the buffer.
            sendOffsets[fd] = newOffset
            guard let sqe = sl_get_sqe(&ring) else { return }
            sendBuffers[fd]!.withUnsafeBufferPointer { ptr in
                let remainingPtr = ptr.baseAddress!.advanced(by: newOffset)
                let remainingLen = UInt32(totalLen - newOffset)
                sl_prep_send(sqe, fd, remainingPtr, remainingLen)
            }
            sl_sqe_set_data(sqe, packUserData(fd: fd, op: .send))
            _ = sl_submit(&ring)
            return
        }

        // Full response sent — clean up and proceed.
        sendBuffers[fd] = nil
        sendOffsets[fd] = nil
        let keepAlive = sendKeepAlive.removeValue(forKey: fd) ?? true

        if !keepAlive {
            closeConnection(fd: fd)
            return
        }

        // Keep-alive: try to process pipelined requests that are
        // already in the codec's accumulator (no new TCP data needed).
        // If none available, re-arm RECV to wait for the next request.
        if let codec = codecs[fd], let readBuf = readBuffers[fd] {
            // Check if there's buffered data in the accumulator that
            // constitutes another complete request (pipelining).
            let result = codec.tryParseSync()
            switch result {
            case .response(let response):
                submitSend(fd: fd, response: response)
            case .incomplete:
                submitRecv(fd: fd, buf: readBuf)
            case .needsAsync:
                let r = HTTPResponse.plaintext(
                    "500 Async handlers require NIO backend\n",
                    status: .internalServerError, keepAlive: false)
                codec.afterDispatch()
                submitSend(fd: fd, response: r)
            }
        } else {
            closeConnection(fd: fd)
        }
    }

    // MARK: - Wakeup (eventfd for async responses)

    private func submitWakeupPoll() throws {
        guard let sqe = sl_get_sqe(&ring) else { return }
        sl_prep_poll_add(sqe, wakeupFd, 0x0001 /* POLLIN */, 1 /* multishot */)
        sl_sqe_set_data(sqe, packUserData(fd: wakeupFd, op: .poll))
    }

    private func handleWakeup() {
        var val: UInt64 = 0
        _ = withUnsafeMutablePointer(to: &val) { ptr in
            read(wakeupFd, ptr, 8)
        }
    }

    // MARK: - Async response queue

    func enqueueResponse(fd: CInt, data: [UInt8], keepAlive: Bool) {
        pthread_mutex_lock(&responseLock)
        responseQueue.append((fd, data, keepAlive))
        pthread_mutex_unlock(&responseLock)
    }

    func wakeup() {
        var val: UInt64 = 1
        _ = withUnsafePointer(to: &val) { ptr in
            write(wakeupFd, ptr, 8)
        }
    }

    private func drainResponseQueue() {
        pthread_mutex_lock(&responseLock)
        let pending = responseQueue
        responseQueue.removeAll(keepingCapacity: true)
        pthread_mutex_unlock(&responseLock)

        for item in pending {
            sendBuffers[item.fd] = item.data
            sendKeepAlive[item.fd] = item.keepAlive
            guard let sqe = sl_get_sqe(&ring) else { continue }
            item.data.withUnsafeBufferPointer { ptr in
                sl_prep_send(sqe, item.fd, ptr.baseAddress!, UInt32(ptr.count))
            }
            sl_sqe_set_data(sqe, packUserData(fd: item.fd, op: .send))
        }
    }

    // MARK: - Cleanup

    private func closeConnection(fd: CInt) {
        if let buf = readBuffers.removeValue(forKey: fd) {
            buf.deallocate()
        }
        sendBuffers[fd] = nil
        sendOffsets[fd] = nil
        sendKeepAlive[fd] = nil
        codecs[fd] = nil
        close(fd)
    }

    func shutdown() {
        stopped = true
        wakeup()
    }
}

// MARK: - Error

struct StarlightIOError: Error, CustomStringConvertible {
    let code: Int32
    let function: String
    var description: String {
        "StarlightIOError(\(function)): \(String(cString: strerror(code))) [\(code)]"
    }
}

#endif // os(Linux)
