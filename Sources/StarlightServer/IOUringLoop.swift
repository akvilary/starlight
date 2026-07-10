//===----------------------------------------------------------------------===//
//
//  IOUringLoop.swift
//  StarlightServer
//
//  Per-thread io_uring event loop — Linux only.
//
//  ─── Architecture ──────────────────────────────────────────────────────
//
//  One IOUringLoop per CPU core, each on a dedicated Thread:
//
//    ┌─── io_uring thread ─────────────────────────────────────────┐
//    │                                                              │
//    │  sl_wait_cqe(ring) → blocks until ≥1 CQE arrives           │
//    │    │                                                         │
//    │    ├─ ACCEPT CQE (POLL_ADD on listener fired):              │
//    │    │    accept4() drain → TCP_NODELAY → RECV SQE per conn   │
//    │    │    re-arm POLL_ADD (if under connection limit)         │
//    │    │                                                         │
//    │    ├─ RECV CQE (data arrived on connection fd):             │
//    │    │    copy read buffer → feed codec → tryParseSync        │
//    │    │       .response   → SEND SQE immediately              │
//    │    │       .incomplete  → RECV SQE (need more data)        │
//    │    │       .needsAsync  → 500 (Phase 2: eventfd + Task)    │
//    │    │                                                         │
//    │    ├─ SEND CQE (write completed):                           │
//    │    │    partial? → SEND remaining bytes                     │
//    │    │    full? → keep-alive? process pipelined / RECV : close│
//    │    │                                                         │
//    │    └─ POLL CQE (eventfd fired — async response ready):     │
//    │         drain response queue → SEND SQEs                    │
//    │                                                              │
//    │  All state (connections, buffers, codecs) is thread-local.  │
//    │  No locks, no cross-thread sharing in the hot path.         │
//    │                                                              │
//    └──────────────────────────────────────────────────────────────┘
//
//  ─── Connection lifecycle ──────────────────────────────────────────────
//
//  ACCEPT → create per-conn read buffer + codec → RECV SQE
//    → RECV CQE → feed codec → parse → handler → SEND SQE
//    → SEND CQE → keep-alive? try pipelined → RECV : close
//
//  Per-connection resources (allocated at accept, freed at close):
//    • 8 KB read buffer (UnsafeMutablePointer<UInt8>)
//    • HTTP1Codec (parser + arena + accumulator)
//
//  ─── user_data packing ────────────────────────────────────────────────
//
//  Each SQE carries a 64-bit user_data tag that io_uring returns
//  unchanged in the CQE. We pack (fd, operation_type) into it:
//
//    bits  0–31: socket file descriptor (CInt, 32-bit)
//    bits 32–39: operation type (accept=1, recv=2, send=3, poll=4)
//    bits 40–63: reserved (future: sequence numbers)
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

/// Operation type encoded into SQE user_data bits 32–39.
/// Lets us identify which kind of operation a CQE corresponds to
/// without maintaining a separate tracking table.
internal enum IouringOp: UInt64 {
    case accept = 1  // POLL_ADD on listener fd
    case recv   = 2  // IORING_OP_RECV on connection fd
    case send   = 3  // IORING_OP_SEND on connection fd
    case poll   = 4  // POLL_ADD on eventfd (async wakeup)
}

/// Pack (fd, op) into a 64-bit user_data value for SQE.
@inline(__always)
internal func packUserData(fd: CInt, op: IouringOp) -> UInt64 {
    // UInt32(bitPattern:) preserves negative fd values correctly.
    UInt64(UInt32(bitPattern: fd)) | (op.rawValue << 32)
}

/// Extract the file descriptor from a CQE's user_data.
@inline(__always)
internal func unpackFD(_ data: UInt64) -> CInt {
    CInt(bitPattern: UInt32(truncatingIfNeeded: data))
}

/// Extract the operation type from a CQE's user_data.
@inline(__always)
internal func unpackOp(_ data: UInt64) -> IouringOp {
    IouringOp(rawValue: data >> 32) ?? .accept
}

// MARK: - IOUringLoop

/// Per-thread io_uring event loop. Owns one ring, one listener socket,
/// and all connections accepted on this thread.
///
/// **Thread safety**: All ring operations (`sl_get_sqe`, `sl_submit`,
/// `sl_wait_cqe`) and dictionary access happen on the loop's dedicated
/// thread. The only cross-thread access is the response queue
/// (protected by `responseLock`) and the `stopped` flag.
final class IOUringLoop: @unchecked Sendable {

    // ── io_uring ring + file descriptors ────────────────────────────
    private var ring = sl_ring()
    private var listenerFd: CInt = -1
    private var wakeupFd: CInt = -1  // eventfd for async wakeup

    // ── Configuration ───────────────────────────────────────────────
    private let host: String
    private let port: Int
    private let handler: HTTPHandler?
    private let router: Router?
    private let ringEntries: UInt32 = 512
    private let readBufferSize: Int = 8192

    /// Maximum concurrent connections per loop. When this limit is
    /// reached, new accepts are paused (POLL_ADD not re-armed) until
    /// a connection closes. Prevents OOM under connection-flood DoS.
    /// Total server limit = maxConnectionsPerLoop × loopCount.
    private let maxConnectionsPerLoop: Int
    internal let loopStats: ServerStats

    // ── Per-connection state (thread-local, no locks) ───────────────

    /// fd → pre-allocated 8 KB read buffer.
    /// Allocated once at accept, freed at close. Reused across
    /// keep-alive requests on the same connection.
    private var readBuffers: [CInt: UnsafeMutablePointer<UInt8>] = [:]

    /// fd → send buffer bytes. The array is kept alive until the SEND
    /// CQE arrives, ensuring the pointer given to io_uring remains
    /// valid. Swift Array<UInt8> uses contiguous heap storage that
    /// does not relocate — the pointer from withUnsafeBufferPointer
    /// remains stable as long as the array reference is held and the
    /// array is not mutated between SQE submission and CQE completion.
    private var sendBuffers: [CInt: [UInt8]] = [:]

    /// fd → bytes already sent (tracks partial writes so we can
    /// re-submit only the unsent tail).
    private var sendOffsets: [CInt: Int] = [:]

    /// fd → keep-alive flag (set when response is submitted, read
    /// when SEND CQE arrives to decide next action).
    private var sendKeepAlive: [CInt: Bool] = [:]

    /// fd → HTTP1Codec (parser + arena + accumulator). One per
    /// connection, reused across all keep-alive requests.
    private var codecs: [CInt: HTTP1Codec] = [:]

    // ── Scratch buffer (avoids per-read ByteBuffer allocation) ──────
    //
    // Each RECV CQE creates a ByteBuffer from the raw read buffer to
    // feed into the codec. Without this scratch buffer, we'd allocate
    // a new ByteBuffer per read event. Since the loop is single-
    // threaded, this scratch is safe to reuse across connections.

    /// Reusable ByteBuffer for feeding read data into codec.
    /// Cleared and refilled per RECV CQE.
    private var scratchRecvBuf = ByteBufferAllocator().buffer(capacity: 8192)

    // ── Async response queue (thread-safe) ──────────────────────────
    //
    // When async handlers are supported (Phase 2), pool threads will
    // enqueue completed responses here and wake the loop via eventfd.
    // The loop drains this queue at the end of each CQE batch.

    private var responseQueue: [(fd: CInt, data: [UInt8], keepAlive: Bool)] = []
    private var responseLock = pthread_mutex_t()

    // ── Lifecycle ───────────────────────────────────────────────────
    private var stopped = false

    /// Number of currently open connections on this loop.
    private var connectionCount: Int = 0

    init(host: String, port: Int, handler: HTTPHandler?, router: Router?,
         stats: ServerStats, maxConnectionsPerLoop: Int = 10_000) {
        self.host = host
        self.port = port
        self.handler = handler
        self.router = router
        self.loopStats = stats
        self.maxConnectionsPerLoop = maxConnectionsPerLoop
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

    /// Initialize the ring, bind the listener, submit initial SQEs.
    /// Must be called once before `run()`.
    func setup() throws {
        // Create the io_uring instance.
        let ret = sl_ring_init(&ring, ringEntries)
        guard ret == 0 else {
            throw StarlightIOError(code: Int32(ret), function: "sl_ring_init")
        }

        // Bind a non-blocking TCP listener with SO_REUSEADDR + SO_REUSEPORT.
        // Each loop thread gets its own listener fd; the kernel load-
        // balances incoming connections across them (H2O pattern).
        let lfd = host.withCString { ptr in
            sl_listen(ptr, Int32(port), Int32(1024))
        }
        guard lfd >= 0 else {
            throw StarlightIOError(code: Int32(-lfd), function: "sl_listen")
        }
        listenerFd = lfd

        // Create eventfd for async-handler wakeup (Phase 2 infrastructure).
        // EFD_NONBLOCK (0x800) | EFD_CLOEXEC (0x80000) = 2048 | 524288.
        let efd = eventfd(0, 2048 | 524288)
        guard efd >= 0 else {
            throw StarlightIOError(code: Int32(errno), function: "eventfd")
        }
        wakeupFd = efd

        // Submit initial operations:
        //   1. POLL_ADD on listener fd — fires when a new connection arrives
        //   2. POLL_ADD on eventfd    — fires when an async handler completes
        try submitAccept()
        try submitWakeupPoll()
        _ = sl_submit(&ring)  // flush both SQEs to kernel immediately
    }

    // MARK: - Event loop

    /// The main event loop. Blocks until `shutdown()` is called.
    ///
    /// Each iteration:
    /// 1. `sl_wait_cqe` — blocks until ≥1 CQE is available, then
    ///    flushes any pending SQEs and enters the kernel.
    /// 2. Process all available CQEs in a batch (peeks after each one).
    /// 3. Drain the async response queue (for Phase 2 async handlers).
    func run() throws {
        while !stopped {
            var cqe: UnsafeMutablePointer<io_uring_cqe>? = nil
            let ret = sl_wait_cqe(&ring, &cqe)

            // EINTR: interrupted by signal — retry.
            // EAGAIN: transient — retry.
            if ret < 0 {
                if -ret == EINTR || -ret == EAGAIN { continue }
                throw StarlightIOError(code: Int32(ret), function: "sl_wait_cqe")
            }
            guard let first = cqe else { continue }

            // Drain all available CQEs without re-entering the kernel.
            // sl_peek_cqe is non-blocking — returns 0 when the CQ is empty.
            var current: UnsafeMutablePointer<io_uring_cqe>? = first
            while current != nil {
                processCQE(current!)
                sl_cqe_seen(&ring)  // advance CQ head — kernel can reuse slot
                let n = sl_peek_cqe(&ring, &current)
                if n == 0 { break }
            }

            // Check for async handler completions (Phase 2).
            drainResponseQueue()
        }
        sl_ring_exit(&ring)
    }

    // MARK: - CQE dispatch

    /// Route a CQE to the appropriate handler based on its user_data tag.
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

    /// Submit a POLL_ADD SQE on the listener fd. When a new connection
    /// arrives, the kernel completes the poll and we call accept4().
    ///
    /// We use POLL_ADD + accept4 instead of IORING_OP_ACCEPT because
    /// the latter has compatibility issues on some kernel configurations
    /// and NIO uses the same POLL_ADD approach.
    ///
    /// POLL_ADD is NOT multishot here (we pass multishot=0 via sl_prep_accept
    /// which doesn't set the IORING_POLL_ADD_MULTI flag). Each completion
    /// requires re-arming. This gives us natural back-pressure: if we
    /// don't re-arm, new connections queue in the kernel's backlog.
    private func submitAccept() throws {
        guard let sqe = sl_get_sqe(&ring) else { return }
        sl_prep_accept(sqe, listenerFd)
        sl_sqe_set_data(sqe, packUserData(fd: listenerFd, op: .accept))
    }

    /// Handle POLL_ADD completion on the listener fd.
    /// Drains all pending connections from the accept backlog.
    private func handleAccept(res: CInt) {
        // res > 0 from POLL_ADD means the requested events (POLLIN)
        // are ready — connections are pending. Drain them all.
        while true {
            let fd = sl_accept4(listenerFd)
            if fd >= 0 {
                setupNewConnection(fd: fd)
            } else if fd == -EINTR {
                // Signal interrupted accept4 — retry immediately.
                continue
            } else {
                // -EAGAIN: no more pending connections (normal).
                // Other errors: log and move on.
                break
            }
        }

        // Re-arm POLL_ADD only if under the connection limit.
        // This is our back-pressure mechanism: when at capacity,
        // new connections wait in the kernel's TCP backlog until
        // an existing connection closes and we re-arm.
        if connectionCount < maxConnectionsPerLoop {
            try? submitAccept()
        }
    }

    /// Set up per-connection state and submit the first RECV.
    private func setupNewConnection(fd: CInt) {
        // TCP_NODELAY — disable Nagle's algorithm so small responses
        // are sent immediately without waiting for more data to batch.
        // H2O, fasthttp, and Go's net/http all set this by default.
        _ = sl_set_tcp_nodelay(fd)
        _ = loopStats.connectionsAccepted.increment()
        connectionCount += 1

        // Allocate per-connection read buffer (8 KB). This buffer is
        // reused for every RECV on this connection. It's the backing
        // store that io_uring's RECV operation writes into.
        let readBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: readBufferSize)
        readBuffers[fd] = readBuf

        // Create per-connection codec. One HTTP1Codec per connection,
        // reused across all keep-alive requests — same pattern as
        // fasthttp's RequestCtx and H2O's http1_conn_t.
        if let router = router {
            codecs[fd] = HTTP1Codec(router: router)
        } else if let handler = handler {
            codecs[fd] = HTTP1Codec(handler: handler)
        }

        // Submit the first RECV SQE — waits for the client to send
        // the HTTP request.
        submitRecv(fd: fd, buf: readBuf)
    }

    // MARK: - Recv

    /// Submit a RECV SQE for the given connection. The kernel will
    /// read up to `readBufferSize` bytes from the socket into `buf`
    /// and post a CQE when data is available.
    private func submitRecv(fd: CInt, buf: UnsafeMutablePointer<UInt8>) {
        guard let sqe = sl_get_sqe(&ring) else { return }
        sl_prep_recv(sqe, fd, buf, UInt32(readBufferSize))
        sl_sqe_set_data(sqe, packUserData(fd: fd, op: .recv))
        _ = sl_submit(&ring)
    }

    /// Handle RECV completion: data arrived on a connection.
    private func handleRecv(fd: CInt, bytesRead: CInt) {
        // bytesRead == 0: client closed the connection (EOF).
        // bytesRead < 0: error (connection reset, etc.).
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

        // Copy read data into the reusable scratch ByteBuffer and feed
        // to the codec. The codec's feed() copies bytes into its internal
        // accumulator, so the scratch buffer can be reused immediately.
        //
        // We use a per-loop scratch buffer instead of allocating a new
        // ByteBuffer per read — avoids a heap allocation per RECV CQE.
        scratchRecvBuf.clear()
        scratchRecvBuf.writeBytes(UnsafeBufferPointer(
            start: readBuf, count: Int(bytesRead)))
        codec.feed(scratchRecvBuf)

        // Parse + dispatch (handles pipelining: multiple requests
        // in one TCP segment are processed in a loop).
        processRequests(fd: fd, codec: codec, readBuf: readBuf)
    }

    /// Process as many pipelined requests as the codec has buffered.
    /// Loops until: incomplete (need more data), response sent, or
    /// async handler encountered.
    private func processRequests(fd: CInt, codec: HTTP1Codec,
                                  readBuf: UnsafeMutablePointer<UInt8>) {
        while true {
            let result = codec.tryParseSync()

            switch result {
            case .incomplete:
                // Not enough data for a complete request yet.
                // Re-arm RECV to wait for more bytes from the client.
                submitRecv(fd: fd, buf: readBuf)
                return

            case .response(let response):
                // Sync handler produced a response — submit SEND SQE.
                // RECV will be re-armed after SEND completes (to
                // respect HTTP/1.1 pipelining ordering: responses
                // must be sent in request order).
                submitSend(fd: fd, response: response)
                return

            case .needsAsync:
                // Async handler encountered. Phase 1 returns a 500
                // error — the eventfd + response queue infrastructure
                // is in place for Phase 2 but the actual async dispatch
                // is not yet wired up.
                //
                // Phase 2 plan: spawn a Task that calls
                // codec.dispatchAsync(), enqueue the response via
                // enqueueResponse(), and wakeup() the loop via eventfd.
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

    /// Submit a SEND SQE for the given connection.
    ///
    /// Copies the response bytes into a `[UInt8]` owned by the loop
    /// (stored in `sendBuffers[fd]`). This array stays alive until the
    /// SEND CQE arrives, ensuring the pointer passed to io_uring
    /// remains valid for the kernel to read from.
    ///
    /// The copy is necessary because HTTPResponse's ByteBuffer uses COW
    /// — multiple connections might share the same backing storage
    /// (e.g., pre-cached "Hello, World!" response). We need exclusive
    /// ownership until the kernel finishes reading the bytes.
    private func submitSend(fd: CInt, response: HTTPResponse) {
        // Flatten header + body into one contiguous byte array.
        var bytes = Array(response.headerBuffer.readableBytesView)
        if let body = response.bodyBuffer {
            bytes.append(contentsOf: body.readableBytesView)
        }

        _ = loopStats.bytesSent.add(Int64(bytes.count))

        sendBuffers[fd] = bytes
        sendKeepAlive[fd] = response.keepAlive
        sendOffsets[fd] = 0  // no bytes sent yet

        guard let sqe = sl_get_sqe(&ring) else { return }
        // Source the pointer from sendBuffers[fd] (the stable copy
        // in the dictionary), NOT from the local `bytes` variable.
        // The dictionary entry outlives this function call and keeps
        // the array's backing storage alive until the CQE arrives.
        sendBuffers[fd]!.withUnsafeBufferPointer { ptr in
            sl_prep_send(sqe, fd, ptr.baseAddress!, UInt32(ptr.count))
        }
        sl_sqe_set_data(sqe, packUserData(fd: fd, op: .send))
        _ = sl_submit(&ring)  // flush immediately — minimize response latency
    }

    /// Handle SEND completion.
    ///
    /// Three cases:
    /// 1. **Error** (bytesWritten < 0): connection broke — close.
    /// 2. **Partial write** (bytesWritten < total): socket send buffer
    ///    was full. Re-submit SEND for the remaining bytes.
    /// 3. **Full write**: response sent. If keep-alive, check for
    ///    pipelined requests. Otherwise close.
    private func handleSend(fd: CInt, bytesWritten: CInt) {
        if bytesWritten < 0 {
            closeConnection(fd: fd)
            return
        }

        // ── Partial write handling ─────────────────────────────────
        //
        // The kernel may accept fewer bytes than we submitted if the
        // socket's send buffer is full (slow client, network congestion).
        // We track how many bytes have been sent so far and re-submit
        // only the unsent tail.
        let offset = sendOffsets[fd] ?? 0
        let totalLen = sendBuffers[fd]?.count ?? 0
        let newOffset = offset + Int(bytesWritten)

        if newOffset < totalLen {
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

        // ── Full response sent — clean up ──────────────────────────
        sendBuffers[fd] = nil
        sendOffsets[fd] = nil
        let keepAlive = sendKeepAlive.removeValue(forKey: fd) ?? true

        if !keepAlive {
            closeConnection(fd: fd)
            return
        }

        // Keep-alive: check for pipelined requests already buffered in
        // the codec's accumulator (sent in the same TCP segment as the
        // previous request). If found, process and send immediately.
        // If not, re-arm RECV to wait for the next request.
        if let codec = codecs[fd], let readBuf = readBuffers[fd] {
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

    // MARK: - Wakeup (eventfd for async handler completions)

    /// Submit a multishot POLL_ADD on the eventfd. When a pool thread
    /// writes to the eventfd (after an async handler completes), this
    /// poll fires and wakes the loop to drain the response queue.
    private func submitWakeupPoll() throws {
        guard let sqe = sl_get_sqe(&ring) else { return }
        // 0x0001 = POLLIN. multishot=1 means the kernel re-arms
        // automatically after each completion — we don't need to
        // re-submit.
        sl_prep_poll_add(sqe, wakeupFd, 0x0001, 1)
        sl_sqe_set_data(sqe, packUserData(fd: wakeupFd, op: .poll))
    }

    /// Handle eventfd wakeup: read to clear the counter, then
    /// drainResponseQueue() will be called by the main loop.
    private func handleWakeup() {
        // Reading eventfd clears its counter (resets to 0).
        // The 8-byte read returns the value written by the pool thread.
        var val: UInt64 = 0
        _ = withUnsafeMutablePointer(to: &val) { ptr in
            read(wakeupFd, ptr, 8)
        }
    }

    // MARK: - Async response queue (thread-safe)

    /// Enqueue a completed async response. Called from pool threads
    /// after an async handler finishes execution.
    func enqueueResponse(fd: CInt, data: [UInt8], keepAlive: Bool) {
        pthread_mutex_lock(&responseLock)
        responseQueue.append((fd, data, keepAlive))
        pthread_mutex_unlock(&responseLock)
    }

    /// Wake the event loop. Called after enqueueResponse() to notify
    /// the loop that work is available.
    func wakeup() {
        var val: UInt64 = 1
        _ = withUnsafePointer(to: &val) { ptr in
            write(wakeupFd, ptr, 8)
        }
    }

    /// Drain pending async responses and submit SEND SQEs for each.
    /// Called on the loop thread after each CQE batch.
    private func drainResponseQueue() {
        pthread_mutex_lock(&responseLock)
        let pending = responseQueue
        responseQueue.removeAll(keepingCapacity: true)
        pthread_mutex_unlock(&responseLock)

        for item in pending {
            sendBuffers[item.fd] = item.data
            sendKeepAlive[item.fd] = item.keepAlive
            sendOffsets[item.fd] = 0
            guard let sqe = sl_get_sqe(&ring) else { continue }
            item.data.withUnsafeBufferPointer { ptr in
                sl_prep_send(sqe, item.fd, ptr.baseAddress!, UInt32(ptr.count))
            }
            sl_sqe_set_data(sqe, packUserData(fd: item.fd, op: .send))
        }
        if !pending.isEmpty {
            _ = sl_submit(&ring)
        }
    }

    // MARK: - Connection cleanup

    /// Close a connection and free all its resources.
    ///
    /// Note on pending SQEs: there may be in-flight RECV or SEND SQEs
    /// for this fd. After close(fd), the kernel will complete them with
    /// -EBADF or -ECANCELED. Our CQE handlers treat negative results as
    /// connection errors and call closeConnection again — the second
    /// call is a no-op because the fd is already removed from all
    /// dictionaries. This is correct but slightly wasteful.
    ///
    /// A future optimization could submit IORING_OP_ASYNC_CANCEL to
    /// cancel pending SQEs proactively.
    private func closeConnection(fd: CInt) {
        if let buf = readBuffers.removeValue(forKey: fd) {
            buf.deallocate()
        }
        sendBuffers[fd] = nil
        sendOffsets[fd] = nil
        sendKeepAlive[fd] = nil
        codecs[fd] = nil
        close(fd)

        connectionCount -= 1

        // If we were at the connection limit, a slot just freed up.
        // Re-arm POLL_ADD to start accepting again.
        if connectionCount == maxConnectionsPerLoop - 1 {
            try? submitAccept()
            _ = sl_submit(&ring)
        }
    }

    // MARK: - Shutdown

    /// Signal the loop to stop after the current iteration.
    func shutdown() {
        stopped = true
        wakeup()  // break out of sl_wait_cqe
    }
}

// MARK: - Error type

struct StarlightIOError: Error, CustomStringConvertible {
    let code: Int32
    let function: String
    var description: String {
        "StarlightIOError(\(function)): \(String(cString: strerror(code))) [\(code)]"
    }
}

#endif // os(Linux)
