//===----------------------------------------------------------------------===//
//
//  IOUringLoop.swift
//  StarlightServer
//
//  Per-thread io_uring event loop — Linux only.
//
//  ─── Architecture ──────────────────────────────────────────────────────
//
//  One IOUringLoop per CPU core, each on a dedicated Thread.
//  All connection state lives in a single IOConnection object —
//  one dictionary lookup per request instead of five.
//
//  ─── Batch submission ──────────────────────────────────────────────────
//
//  SQEs are filled during CQE processing but NOT submitted per-op.
//  sl_wait_cqe at the top of the loop flushes all pending SQEs in
//  a single io_uring_enter syscall:
//
//    ┌─── loop iteration ───────────────────────────────────────────┐
//    │  sl_wait_cqe → flushes ALL pending SQEs + waits for ≥1 CQE │
//    │    │                                                         │
//    │    ├─ ACCEPT → accept4 drain → new IOConnection → fill RECV │
//    │    ├─ RECV   → feed(UnsafeBufferPointer) → parse → fill SEND│
//    │    ├─ SEND   → partial? fill SEND : keep-alive? fill RECV   │
//    │    └─ POLL   → drain async queue → fill SENDs               │
//    │                                                              │
//    │  (SQEs are filled above but NOT submitted — they accumulate) │
//    │  drainResponseQueue()                                        │
//    └── loop back: sl_wait_cqe flushes everything in one syscall ─┘
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

// MARK: - IOConnection

/// All per-connection state in one object.
///
/// The key insight: ByteBuffer uses heap-allocated, reference-counted
/// backing storage that never moves. We store the response's ByteBuffer
/// in `pendingResponse` to keep it alive, and pass its backing pointer
/// directly to io_uring SEND — zero copy, zero allocation.
final class IOConnection {
    let fd: CInt
    let readBuffer: UnsafeMutablePointer<UInt8>
    let codec: HTTP1Codec

    /// The response being sent. Kept alive until SEND CQE arrives
    /// so io_uring can read from the ByteBuffer's backing storage.
    var pendingResponse: HTTPResponse?
    /// Alternative: raw bytes from the async response queue.
    var pendingSendData: [UInt8]?

    var sendOffset: Int = 0
    var keepAlive: Bool = true

    init(fd: CInt, readBufferSize: Int, router: Router?, handler: HTTPHandler?) {
        self.fd = fd
        self.readBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: readBufferSize)
        if let router = router {
            self.codec = HTTP1Codec(router: router)
        } else {
            self.codec = HTTP1Codec(handler: handler!)
        }
    }

    deinit {
        readBuffer.deallocate()
    }

    /// Total bytes to send.
    var sendLen: Int {
        if let r = pendingResponse {
            return r.headerBuffer.readableBytes + (r.bodyBuffer?.readableBytes ?? 0)
        }
        return pendingSendData?.count ?? 0
    }

    /// Submit SEND SQE using the pending data's pointer directly.
    /// Called within `withUnsafeReadableBytes` / `withUnsafeBufferPointer`
    /// so the pointer is valid during the `sl_prep_send` call.
    /// The backing storage stays alive via pendingResponse / pendingSendData.
    func fillSendSQE(_ sqe: UnsafeMutablePointer<io_uring_sqe>, offset: Int) {
        let total = sendLen
        let remaining = total - offset

        if let r = pendingResponse {
            // Single-buffer (all current responses): one pointer.
            if r.bodyBuffer == nil {
                r.headerBuffer.withUnsafeReadableBytes { ptr in
                    sl_prep_send(sqe, fd,
                                 ptr.baseAddress!.advanced(by: offset),
                                 UInt32(remaining))
                }
            } else {
                // Multi-buffer: flatten. (Future: WRITEV.)
                // For now this path is never taken.
                let hdr = r.headerBuffer.readableBytes
                if offset < hdr {
                    let hdrLen = UInt32(hdr - offset)
                    r.headerBuffer.withUnsafeReadableBytes { ptr in
                        sl_prep_send(sqe, fd,
                                     ptr.baseAddress!.advanced(by: offset),
                                     hdrLen)
                    }
                } else {
                    let bodyOff = offset - hdr
                    let bodyLen = UInt32(remaining)
                    r.bodyBuffer!.withUnsafeReadableBytes { ptr in
                        sl_prep_send(sqe, fd,
                                     ptr.baseAddress!.advanced(by: bodyOff),
                                     bodyLen)
                    }
                }
            }
        } else if let data = pendingSendData {
            data.withUnsafeBufferPointer { ptr in
                sl_prep_send(sqe, fd,
                             ptr.baseAddress!.advanced(by: offset),
                             UInt32(remaining))
            }
        }
    }

    /// Clear send state after SEND completes.
    func clearSend() {
        pendingResponse = nil
        pendingSendData = nil
        sendOffset = 0
    }
}

// MARK: - IOUringLoop

final class IOUringLoop: @unchecked Sendable {

    private var ring = sl_ring()
    private var listenerFd: CInt = -1
    private var wakeupFd: CInt = -1

    private let host: String
    private let port: Int
    private let handler: HTTPHandler?
    private let router: Router?
    private let ringEntries: UInt32 = 4096
    private let readBufferSize: Int = 8192
    private let maxConnectionsPerLoop: Int
    internal let loopStats: ServerStats

    /// Single dictionary: fd → IOConnection. One lookup per request.
    private var connections: [CInt: IOConnection] = [:]

    private var responseQueue: [(fd: CInt, data: [UInt8], keepAlive: Bool)] = []
    private var responseLock = pthread_mutex_t()

    private var stopped = false
    private var connectionCount: Int = 0

    init(host: String, port: Int, handler: HTTPHandler?, router: Router?,
         stats: ServerStats, maxConnectionsPerLoop: Int = 10_000) {
        self.host = host
        self.port = port
        self.handler = handler
        self.router = router
        self.loopStats = stats
        let ringCapacity = Int(ringEntries) - 4
        self.maxConnectionsPerLoop = min(maxConnectionsPerLoop, ringCapacity)
        pthread_mutex_init(&responseLock, nil)
    }

    deinit {
        pthread_mutex_destroy(&responseLock)
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

        let efd = eventfd(0, 2048 | 524288)
        guard efd >= 0 else {
            throw StarlightIOError(code: Int32(errno), function: "eventfd")
        }
        wakeupFd = efd

        submitAccept()
        submitWakeupPoll()
        _ = sl_submit(&ring)
    }

    // MARK: - Event loop (batch submission)

    func run() throws {
        while !stopped {
            // sl_wait_cqe flushes ALL pending SQEs (filled during the
            // previous iteration) and then blocks for ≥1 CQE.
            // This is the ONLY io_uring_enter per loop iteration.
            var cqe: UnsafeMutablePointer<io_uring_cqe>? = nil
            let ret = sl_wait_cqe(&ring, &cqe)

            if ret < 0 {
                if -ret == EINTR || -ret == EAGAIN { continue }
                throw StarlightIOError(code: Int32(ret), function: "sl_wait_cqe")
            }
            guard let first = cqe else { continue }

            // Process all available CQEs in a batch.
            // Each handler fills new SQEs but does NOT submit them.
            // Submission happens at the top of the next iteration.
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

    // MARK: - SQE allocation

    /// Get an SQE, flushing once if the ring is full.
    private func ensureSQE() -> UnsafeMutablePointer<io_uring_sqe>? {
        if let sqe = sl_get_sqe(&ring) { return sqe }
        _ = sl_submit(&ring)
        return sl_get_sqe(&ring)
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

    private func submitAccept() {
        guard let sqe = ensureSQE() else { return }
        sl_prep_accept(sqe, listenerFd)
        sl_sqe_set_data(sqe, packUserData(fd: listenerFd, op: .accept))
    }

    private func handleAccept(res: CInt) {
        while true {
            let fd = sl_accept4(listenerFd)
            if fd >= 0 {
                setupNewConnection(fd: fd)
            } else if fd == -EINTR {
                continue
            } else {
                break
            }
        }
        if connectionCount < maxConnectionsPerLoop {
            submitAccept()
        }
    }

    private func setupNewConnection(fd: CInt) {
        // TCP_NODELAY + keepalive (60s idle → 3 probes × 10s)
        _ = sl_set_tcp_nodelay(fd)
        sl_set_keepalive(fd, 60, 10, 3)

        _ = loopStats.connectionsAccepted.increment()
        connectionCount += 1

        let conn = IOConnection(fd: fd, readBufferSize: readBufferSize,
                                router: router, handler: handler)
        connections[fd] = conn
        submitRecv(conn: conn)
    }

    // MARK: - Recv

    private func submitRecv(conn: IOConnection) {
        guard let sqe = ensureSQE() else {
            closeConnection(conn: conn)
            return
        }
        sl_prep_recv(sqe, conn.fd, conn.readBuffer, UInt32(readBufferSize))
        sl_sqe_set_data(sqe, packUserData(fd: conn.fd, op: .recv))
        // No sl_submit — batched at loop top.
    }

    private func handleRecv(fd: CInt, bytesRead: CInt) {
        guard bytesRead > 0 else {
            if let conn = connections[fd] { closeConnection(conn: conn) }
            return
        }

        _ = loopStats.bytesReceived.add(Int64(bytesRead))

        guard let conn = connections[fd] else { return }

        // Feed raw bytes directly to codec — no intermediate ByteBuffer.
        // Eliminates one heap allocation and one memcpy per read.
        conn.codec.feed(UnsafeBufferPointer(
            start: conn.readBuffer, count: Int(bytesRead)))

        processRequests(conn: conn)
    }

    private func processRequests(conn: IOConnection) {
        while true {
            let result = conn.codec.tryParseSync()

            switch result {
            case .incomplete:
                submitRecv(conn: conn)
                return

            case .response(let response):
                submitSend(conn: conn, response: response)
                return

            case .needsAsync:
                let r = HTTPResponse.plaintext(
                    "500 Async handlers require NIO backend\n",
                    status: .internalServerError, keepAlive: false)
                conn.codec.afterDispatch()
                submitSend(conn: conn, response: r)
                return
            }
        }
    }

    // MARK: - Send

    private func submitSend(conn: IOConnection, response: HTTPResponse) {
        _ = loopStats.bytesSent.add(Int64(response.headerBuffer.readableBytes
                                          + (response.bodyBuffer?.readableBytes ?? 0)))
        conn.pendingResponse = response
        conn.pendingSendData = nil
        conn.sendOffset = 0
        conn.keepAlive = response.keepAlive

        guard let sqe = ensureSQE() else { return }
        conn.fillSendSQE(sqe, offset: 0)
        sl_sqe_set_data(sqe, packUserData(fd: conn.fd, op: .send))
    }

    private func handleSend(fd: CInt, bytesWritten: CInt) {
        guard let conn = connections[fd] else { return }

        if bytesWritten < 0 {
            closeConnection(conn: conn)
            return
        }

        // Partial write: re-submit remaining bytes.
        let newOffset = conn.sendOffset + Int(bytesWritten)
        if newOffset < conn.sendLen {
            conn.sendOffset = newOffset
            guard let sqe = ensureSQE() else { return }
            conn.fillSendSQE(sqe, offset: newOffset)
            sl_sqe_set_data(sqe, packUserData(fd: fd, op: .send))
            return
        }

        // Full response sent.
        conn.clearSend()
        let keepAlive = conn.keepAlive

        if !keepAlive {
            closeConnection(conn: conn)
            return
        }

        // Keep-alive: try pipelined requests from the accumulator.
        let result = conn.codec.tryParseSync()
        switch result {
        case .response(let response):
            submitSend(conn: conn, response: response)
        case .incomplete:
            submitRecv(conn: conn)
        case .needsAsync:
            let r = HTTPResponse.plaintext(
                "500 Async handlers require NIO backend\n",
                status: .internalServerError, keepAlive: false)
            conn.codec.afterDispatch()
            submitSend(conn: conn, response: r)
        }
    }

    // MARK: - Wakeup (eventfd)

    private func submitWakeupPoll() {
        guard let sqe = ensureSQE() else { return }
        sl_prep_poll_add(sqe, wakeupFd, 0x0001, 1)
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
            guard let conn = connections[item.fd] else { continue }
            guard let sqe = ensureSQE() else {
                pthread_mutex_lock(&responseLock)
                responseQueue.insert(item, at: 0)
                pthread_mutex_unlock(&responseLock)
                return
            }
            // Store [UInt8] directly — its backing storage is stable.
            // No copy, no allocation.
            conn.pendingSendData = item.data
            conn.pendingResponse = nil
            conn.sendOffset = 0
            conn.keepAlive = item.keepAlive
            conn.fillSendSQE(sqe, offset: 0)
            sl_sqe_set_data(sqe, packUserData(fd: item.fd, op: .send))
        }
    }

    // MARK: - Connection cleanup

    private func closeConnection(conn: IOConnection) {
        let fd = conn.fd
        connections.removeValue(forKey: fd)
        close(fd)

        connectionCount -= 1

        if connectionCount == maxConnectionsPerLoop - 1 {
            submitAccept()
            // Flush immediately — don't wait for next loop iteration
            // to re-arm the accept, or we might miss connections.
            _ = sl_submit(&ring)
        }
    }

    // MARK: - Shutdown

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
