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
//    │  ensureAcceptArmed() — safety net                           │
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
/// ByteBuffer uses heap-allocated, reference-counted backing storage
/// that never moves. We store the response in `pendingResponse` to
/// keep it alive, and pass its backing pointer directly to io_uring
/// SEND — zero copy, zero allocation.
final class IOConnection {
    let fd: CInt
    let readBuffer: UnsafeMutablePointer<UInt8>
    let codec: HTTP1Codec

    /// Response being sent. Kept alive until SEND CQE arrives.
    var pendingResponse: HTTPResponse?
    /// Alternative: raw bytes from the async response queue.
    var pendingSendData: [UInt8]?

    /// Stored once at submit time — avoids repeated ByteBuffer
    /// property reads in the hot path.
    var sendLen: Int = 0
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

    /// Fill SEND SQE using pending data's pointer directly.
    /// The pointer is valid because pendingResponse / pendingSendData
    /// keep the backing storage alive until the SEND CQE arrives.
    func fillSendSQE(_ sqe: UnsafeMutablePointer<io_uring_sqe>, offset: Int) {
        let remaining = UInt32(sendLen - offset)

        if let r = pendingResponse {
            if r.bodyBuffer == nil {
                // Single-buffer — all current responses take this path.
                r.headerBuffer.withUnsafeReadableBytes { ptr in
                    sl_prep_send(sqe, fd,
                                 ptr.baseAddress!.advanced(by: offset),
                                 remaining)
                }
            } else {
                // Multi-buffer (future: WRITEV).
                let hdr = r.headerBuffer.readableBytes
                if offset < hdr {
                    r.headerBuffer.withUnsafeReadableBytes { ptr in
                        sl_prep_send(sqe, fd,
                                     ptr.baseAddress!.advanced(by: offset),
                                     UInt32(hdr - offset))
                    }
                } else {
                    let bodyOff = offset - hdr
                    r.bodyBuffer!.withUnsafeReadableBytes { ptr in
                        sl_prep_send(sqe, fd,
                                     ptr.baseAddress!.advanced(by: bodyOff),
                                     remaining)
                    }
                }
            }
        } else if let data = pendingSendData {
            data.withUnsafeBufferPointer { ptr in
                sl_prep_send(sqe, fd,
                             ptr.baseAddress!.advanced(by: offset),
                             remaining)
            }
        }
    }

    /// Clear send state after SEND completes.
    func clearSend() {
        pendingResponse = nil
        pendingSendData = nil
        sendLen = 0
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
    private let readBufferSize: Int = 4096
    private let maxConnectionsPerLoop: Int
    internal let loopStats: ServerStats

    /// Single dictionary: fd → IOConnection.
    private var connections: [CInt: IOConnection] = [:]

    private var responseQueue: [(fd: CInt, data: [UInt8], keepAlive: Bool)] = []
    private var responseLock = pthread_mutex_t()

    private var stopped = false
    private var connectionCount: Int = 0

    /// Tracks whether a POLL_ADD for the listener is in-flight.
    /// Prevents duplicate submissions and enables the safety-net
    /// re-arm in the main loop (fixes edge case where ensureSQE
    /// fails during closeConnection's re-arm).
    private var acceptArmed = false

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
            var cqe: UnsafeMutablePointer<io_uring_cqe>? = nil
            let ret = sl_wait_cqe(&ring, &cqe)

            if ret < 0 {
                if -ret == EINTR || -ret == EAGAIN { continue }
                throw StarlightIOError(code: Int32(ret), function: "sl_wait_cqe")
            }
            guard let first = cqe else { continue }

            // Process all available CQEs in a batch.
            var current: UnsafeMutablePointer<io_uring_cqe>? = first
            while current != nil {
                processCQE(current!)
                sl_cqe_seen(&ring)
                let n = sl_peek_cqe(&ring, &current)
                if n == 0 { break }
            }

            drainResponseQueue()
            ensureAcceptArmed()
        }
        sl_ring_exit(&ring)
    }

    // MARK: - SQE allocation

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
        guard !acceptArmed else { return }
        guard let sqe = ensureSQE() else { return }
        sl_prep_accept(sqe, listenerFd)
        sl_sqe_set_data(sqe, packUserData(fd: listenerFd, op: .accept))
        acceptArmed = true
    }

    /// Safety net: if under the connection limit and accept is not
    /// armed (e.g., ensureSQE failed during closeConnection's re-arm),
    /// try again. Called once per loop iteration.
    private func ensureAcceptArmed() {
        if connectionCount < maxConnectionsPerLoop && !acceptArmed {
            submitAccept()
        }
    }

    private func handleAccept(res: CInt) {
        acceptArmed = false

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
    }

    private func handleRecv(fd: CInt, bytesRead: CInt) {
        guard bytesRead > 0 else {
            if let conn = connections[fd] { closeConnection(conn: conn) }
            return
        }

        _ = loopStats.bytesReceived.add(Int64(bytesRead))

        guard let conn = connections[fd] else { return }

        conn.codec.feed(UnsafeBufferPointer(
            start: conn.readBuffer, count: Int(bytesRead)))

        processNextOrRecv(conn: conn)
    }

    // MARK: - Request dispatch (shared by handleRecv and handleSend)

    /// Try to parse and dispatch one request from the codec's accumulator.
    /// - .response → submit SEND (pipelining: next request processed
    ///   after SEND completes to preserve response ordering).
    /// - .incomplete → submit RECV to wait for more data.
    /// - .needsAsync → return 500 (Phase 2: eventfd + Task).
    private func processNextOrRecv(conn: IOConnection) {
        let result = conn.codec.tryParseSync()

        switch result {
        case .incomplete:
            submitRecv(conn: conn)

        case .response(let response):
            submitSend(conn: conn, response: response)

        case .needsAsync:
            let r = HTTPResponse.plaintext(
                "500 Async handlers require NIO backend\n",
                status: .internalServerError, keepAlive: false)
            conn.codec.afterDispatch()
            submitSend(conn: conn, response: r)
        }
    }

    // MARK: - Send

    private func submitSend(conn: IOConnection, response: HTTPResponse) {
        let len = response.headerBuffer.readableBytes
                   + (response.bodyBuffer?.readableBytes ?? 0)
        _ = loopStats.bytesSent.add(Int64(len))

        // Obtain SQE BEFORE mutating connection state.
        // If the ring is full after retry, close the connection
        // rather than leaving it in an inconsistent dead state.
        guard let sqe = ensureSQE() else {
            closeConnection(conn: conn)
            return
        }

        conn.pendingResponse = response
        conn.pendingSendData = nil
        conn.sendLen = len
        conn.sendOffset = 0
        conn.keepAlive = response.keepAlive

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

        if !conn.keepAlive {
            closeConnection(conn: conn)
            return
        }

        // Keep-alive: process pipelined request or re-arm RECV.
        processNextOrRecv(conn: conn)
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
            conn.pendingSendData = item.data
            conn.pendingResponse = nil
            conn.sendLen = item.data.count
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
        // Accept re-arm is handled by ensureAcceptArmed() in the
        // main loop — no need for special-case logic here.
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
