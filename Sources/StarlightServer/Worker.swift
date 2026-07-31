//===----------------------------------------------------------------------===//
//
//  Worker.swift
//  StarlightServer
//
//  Per-event-loop HTTP worker.
//
//  Architecture (revised):
//
//    Worker actor
//    ├── holds listener fd + Worker configuration
//    ├── handleAccept() — drains accept4 queue, spawns Task-per-conn
//    └── Task-per-conn drives the connection lifecycle via async
//        read/write API on PollEventLoop
//
//  Why Task-per-connection after all:
//
//  Swift's async/await fundamentally requires a Task to call async
//  functions. The "no Task per conn" model we explored requires
//  either:
//    (a) sync handlers only — too restrictive
//    (b) sync watch callbacks that dispatch handler via per-request
//        Task — but then keep-alive re-arming fights with epoll
//        registration model (oneshot needs re-register per read)
//
//  Task-per-conn is the model main uses and what hyper+tokio use.
//  The cost is ~200 bytes per conn; for 100K conns that's 20 MB —
//  real but acceptable. v0.2 can explore cooperative scheduling
//  via task group if benchmarks demand it.
//
//  Worker actor still gives us:
//    - Compile-time verified state isolation (no @unchecked)
//    - Pinned to PollEventLoop via unownedExecutor
//    - Sync entry points via assumeIsolated (handleAccept)
//
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
import CLinuxExt
#endif

import Foundation
import HTTP
import HTTPCodec
import Pulsar
import StarlightExtractors   // ConnectInfo
import HTTPPrism

/// Per-connection state. Owned by the per-conn Task frame.
///
/// `H1Conn` (the actor that owns the parser + body state machine)
/// is created by `driveConnection` from these primitives — it lives
/// for the entire keep-alive lifetime of the TCP connection.
struct ConnState: Sendable {
    let fd: CInt
    let channelId: UInt32
    /// Peer address string (e.g. "127.0.0.1:54321"). Obtained via
    /// getpeername(2) at accept time. Inserted into every request's
    /// extensions as `ConnectInfo` for extractors + RateLimitLayer.
    let peerAddress: String
}

/// One HTTP worker. Bound to a `PollEventLoop` via `unownedExecutor`,
/// owns the listener fd, manages all connections accepted on this loop.
public actor Worker {

    // MARK: - Immutable configuration

    public nonisolated let eventLoop: PollEventLoop
    public nonisolated let listenerFd: CInt
    public nonisolated let router: BoxService<Request, Response>
    public nonisolated let cpuIndex: CInt
    public nonisolated let readBufferSize: Int

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        eventLoop.asUnownedSerialExecutor()
    }

    // MARK: - Mutable state

    /// channelId → count of in-flight conns. Used for stats / limits.
    /// Conn state itself lives on per-conn Task frames, not here.
    var inFlightConns: Int = 0
    let maxConnectionsPerWorker: Int

    /// Set by `initiateShutdown()`. While `true`, `handleAccept()`
    /// stops draining the accept queue — no new connections are
    /// accepted, but in-flight Tasks are allowed to complete.
    ///
    /// Stored as a plain `var` — only mutated from inside the actor
    /// (which means: only from the loop thread, via assumeIsolated).
    var isShuttingDown: Bool = false

    /// Continuation resumed when `inFlightConns` reaches 0 (or when
    /// the drain timeout fires). Set by `waitForDrain(...)`, cleared
    /// when resumed. `nil` outside an active drain.
    var drainContinuation: CheckedContinuation<Void, Never>?

    // MARK: - Init

    public init(
        eventLoop: PollEventLoop,
        listenerFd: CInt,
        router: BoxService<Request, Response>,
        cpuIndex: CInt,
        readBufferSize: Int = 8192,
        maxConnectionsPerWorker: Int = 8192
    ) {
        self.eventLoop = eventLoop
        self.listenerFd = listenerFd
        self.router = router
        self.cpuIndex = cpuIndex
        self.readBufferSize = readBufferSize
        self.maxConnectionsPerWorker = maxConnectionsPerWorker
    }

    // MARK: - Entry point

    /// Register the listener watch BEFORE eventLoop.run(). Sync call
    /// (nonisolated) — must be invoked from the worker thread before
    /// the loop starts processing events.
    public nonisolated func registerListenerWatchSync() throws {
        _ = try eventLoop.registerWatch(
            fd: listenerFd,
            interest: .readable
        ) { [weak self] ready in
            guard ready.isReadable else { return }
            guard let self else { return }
            self.assumeIsolated { iso in
                iso.handleAccept()
            }
        }
    }

    // MARK: - Accept

    /// Drain the accept queue. Called from the listener's watch
    /// callback (loop thread, via assumeIsolated). Stops draining
    /// once `isShuttingDown` is set — incoming connections are
    /// still TCP-accepted by the kernel (they sit in the listener's
    /// backlog) but `accept4` is not called, so they wait until the
    /// process exits or the listener fd is closed.
    func handleAccept() {
        if isShuttingDown { return }
        while true {
            let fd = sl_accept4(listenerFd)
            if fd >= 0 {
                acceptConnection(fd: fd)
                continue
            }
            // fd < 0: sl_accept4 returns -errno on failure.
            let err = -fd
            if err == EINTR { continue }  // signal — retry
            break  // EAGAIN/EWOULDBLOCK (drained) or other error
        }
    }

    func acceptConnection(fd: CInt) {
        guard inFlightConns < maxConnectionsPerWorker else {
            #if canImport(Glibc)
            _ = Glibc.close(fd)
            #endif
            return
        }
        inFlightConns &+= 1

        let channelId = eventLoop.registerChannel()
        let peerAddress = Self.getPeerAddress(fd: fd)
        let conn = ConnState(
            fd: fd,
            channelId: channelId,
            peerAddress: peerAddress
        )

        // Spawn a Task to drive this connection's lifecycle.
        // IMPORTANT: driveConnection is a static (non-isolated) method,
        // not an actor method. If it were an actor method, the
        // `await self?.driveConnection(...)` would enqueue a job on
        // eventLoop's queue — but drainJobs() is what's running this
        // Task, so the new job wouldn't be processed until the next
        // drainJobs() call. With poll.poll() blocking on epoll_wait
        // in between, that's a deadlock.
        //
        // By making it non-isolated and passing in only Sendable
        // captures (eventLoop, router, channelId, fd), we sidestep
        // the actor dispatch entirely.
        let bufSize = readBufferSize
        let loop = eventLoop
        let svc = router
        let cpu = cpuIndex
        Task(executorPreference: loop) {
            await Self.driveConnection(
                eventLoop: loop,
                router: svc,
                conn: conn,
                readBufferSize: bufSize
            )
            await self.connectionClosed()
        }
    }

    /// Called when a connection Task exits. Decrements the counter.
    /// If a drain is in progress and the counter reaches 0, resumes
    /// the drain continuation — the worker can now exit cleanly.
    func connectionClosed() {
        inFlightConns &-= 1
        if inFlightConns == 0, let cont = drainContinuation {
            drainContinuation = nil
            cont.resume()
        }
    }

    // MARK: - Graceful shutdown

    /// Stop accepting new connections. Existing per-conn Tasks are
    /// allowed to finish naturally. Called from the serve() shutdown
    /// monitor Task — must be async because it crosses into the
    /// actor from outside.
    public func initiateShutdown() {
        isShuttingDown = true
        // No immediate effect on the listener fd — handleAccept's
        // next invocation will return early. The listener stays
        // open until eventLoop.run() returns.
    }

    /// Wait for all in-flight connections to complete. Returns
    /// immediately if there are none. Resumes when `inFlightConns`
    /// hits 0 OR when `forceShutdown()` is called externally
    /// (timeout path).
    public func waitForDrain() async {
        if inFlightConns == 0 { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            drainContinuation = cont
        }
    }

    /// Force-shutdown: stop the eventLoop. In-flight per-conn Tasks
    /// have their continuations resumed with errors by
    /// `PollEventLoop.recoverOrphanedContinuations()`.
    public nonisolated func forceShutdown() {
        eventLoop.shutdown()
    }

    // MARK: - Per-connection driver (non-isolated)

    /// Drive one connection through its lifetime. Non-isolated so it
    /// can run on the eventLoop Task without going through actor dispatch.
    ///
    /// Architecture (after P0-1 streaming fix):
    ///
    ///   1. `H1Conn` actor (pinned to the eventLoop via its
    ///      `unownedExecutor`) owns the parser state machine and the
    ///      persistent read buffer. `decodeHead` parses request
    ///      headers only — body framing is recorded as
    ///      `.readingBody(remaining)` / `.readingChunkedBody` state.
    ///
    ///   2. After head parsing, `driveConnection` wraps the body in
    ///      `Body.pull { ... }` — a closure that captures `conn` plus
    ///      the generation counter. The closure has zero
    ///      `AsyncThrowingStream` overhead: `Body.collect(maxBytes:)`
    ///      consumes it via a direct `while let chunk = try await next()`
    ///      loop.
    ///
    ///   3. After the handler returns, any unread body bytes are
    ///      drained via `conn.drainBody()` so the buffer is left
    ///      positioned at the next pipelined request. `drainBody`
    ///      also sends the interim `100 Continue` response if the
    ///      handler didn't read the body and the client is still
    ///      waiting on `Expect: 100-continue` (reverse-proxy compat).
    ///
    ///   4. Response is written first, body drain second — clients
    ///      see the response without waiting for the drain to
    ///      complete. `readTimeout` (P0-5) bounds every socket read
    ///      inside the drain.
    ///
    private nonisolated static func driveConnection(
        eventLoop: PollEventLoop,
        router: BoxService<Request, Response>,
        conn initialConn: ConnState,
        readBufferSize: Int
    ) async {
        let fd = initialConn.fd
        let channelId = initialConn.channelId
        let peerAddress = initialConn.peerAddress
        defer {
            #if canImport(Glibc)
            _ = Glibc.close(fd)
            #endif
            eventLoop.cancelChannel(channelId)
        }

        let conn = H1Conn(
            eventLoop: eventLoop,
            fd: fd,
            channelId: channelId,
            maxHeaderBytes: 64 * 1024,
            maxBodyBytes: 2 * 1024 * 1024,
            readTimeout: .seconds(30)
        )
        // Per-EAGAIN-wait bound for response writes. Bounds a stalled
        // reader (client that stops reading): each `awaitWritable` is
        // failed after this, the write aborts, the connection closes.
        // A slow-but-steady reader never stalls this long, so legit
        // slow transfers are unaffected (only stalls are caught).
        let writeTimeout: Duration = .seconds(30)

        // Per-conn encoder (response side) + write buffer — both
        // reused for every keep-alive request on this connection.
        let encoder = H1Encoder()
        var writeBuffer: [UInt8] = []
        writeBuffer.reserveCapacity(2048)

        connLoop: while true {
            // 1. Parse request head (loops internally until headers
            //    are complete, EOF, or parse error).
            let head: DecodedHead
            do {
                guard let h = try await conn.decodeHead() else {
                    // Clean EOF between requests.
                    return
                }
                head = h
            } catch {
                writeErrorAndClose(
                    fd: fd, writeBuffer: &writeBuffer,
                    status: .badRequest, message: "Bad Request"
                )
                return
            }

            // 2. Wire up the lazy body if the request carries one.
            var request = head.request
            if head.hasBody {
                // Capture `conn` and the generation counter so stale
                // body reads after the next keep-alive cycle throw
                // `BodyError.connectionAdvanced` instead of corrupting
                // the next request. The closure has zero
                // `AsyncThrowingStream` overhead — `Body.collect`
                // drives it via a direct `while let chunk = ...` loop.
                let bodyConn = conn
                let myGen = head.generation
                request.body = .pull {
                    try await bodyConn.nextBodyChunk(forGeneration: myGen)
                }
            }

            // 3. Populate ConnectInfo for extractors + RateLimitLayer.
            request.extensions.insert(ConnectInfo(peerAddress: peerAddress))

            let keepAlive = head.keepAlive
            let requestMethod = request.method

            // 4. Dispatch to the router/handler. Errors propagate up
            //    as a 500 + connection close — we don't try to drain
            //    the body in that case (the handler already saw an
            //    error from its extractor or threw voluntarily).
            let response: Response
            do {
                response = try await router.call(request)
            } catch {
                writeErrorAndClose(
                    fd: fd, writeBuffer: &writeBuffer,
                    status: .internalServerError,
                    message: "Internal Server Error"
                )
                return
            }

            // 5. Encode + write response FIRST. The client sees the
            //    response without waiting for any post-handler body
            //    drain (UX: responsive even when the handler ignored
            //    a large body).
            writeBuffer.removeAll(keepingCapacity: true)
            let encoded = encoder.encodeHead(
                response, keepAlive: keepAlive,
                requestMethod: requestMethod,
                into: &writeBuffer
            )
            switch encoded {
            case .noBody:
                if !(await Self.writeAll(fd: fd, writeBuffer[...],
                                          eventLoop: eventLoop, channelId: channelId, writeTimeout: writeTimeout)) {
                    return
                }
            case .buffered:
                if case .buffered(let bodyBytes) = response.body, !bodyBytes.isEmpty {
                    // Optimistic writev: header + body in one syscall.
                    // On loopback (socket buffer >> response size) this
                    // succeeds fully and never crosses an await — the
                    // hot path is a single writev + one comparison.
                    let headerCount = writeBuffer.count
                    let total = headerCount &+ bodyBytes.count
                    let n = Self.writevOnce(fd: fd, header: writeBuffer, body: bodyBytes)
                    if n < total {
                        // Partial write, EAGAIN, or error. Whatever was
                        // already written (`max(n,0)`) is accounted for;
                        // the remainder is flushed via the async loop,
                        // which yields to the loop on EAGAIN.
                        let done = max(n, 0)
                        let headerConsumed = min(done, headerCount)
                        if headerConsumed < headerCount,
                           !(await Self.writeAll(fd: fd, writeBuffer[headerConsumed...],
                                                 eventLoop: eventLoop, channelId: channelId, writeTimeout: writeTimeout)) {
                            return
                        }
                        let bodyConsumed = max(0, done &- headerCount)
                        if bodyConsumed < bodyBytes.count,
                           !(await Self.writeAll(fd: fd, bodyBytes[bodyConsumed...],
                                                 eventLoop: eventLoop, channelId: channelId, writeTimeout: writeTimeout)) {
                            return
                        }
                    }
                } else {
                    if !(await Self.writeAll(fd: fd, writeBuffer[...],
                                              eventLoop: eventLoop, channelId: channelId, writeTimeout: writeTimeout)) {
                        return
                    }
                }
            case .stream:
                // Write header, then stream chunks via chunked TE.
                if !(await Self.writeAll(fd: fd, writeBuffer[...],
                                          eventLoop: eventLoop, channelId: channelId, writeTimeout: writeTimeout)) {
                    return
                }
                do {
                    for try await chunk in response.body.dataStream() {
                        writeBuffer.removeAll(keepingCapacity: true)
                        encoder.encodeChunk(chunk, into: &writeBuffer)
                        if !(await Self.writeAll(fd: fd, writeBuffer[...],
                                                  eventLoop: eventLoop, channelId: channelId, writeTimeout: writeTimeout)) {
                            return
                        }
                    }
                } catch { return }
                writeBuffer.removeAll(keepingCapacity: true)
                encoder.encodeEndOfChunks(into: &writeBuffer)
                if !(await Self.writeAll(fd: fd, writeBuffer[...],
                                          eventLoop: eventLoop, channelId: channelId, writeTimeout: writeTimeout)) {
                    return
                }
            }

            // 6. Connection: close — done after response is flushed.
            if !keepAlive { return }

            // 7. Drain unread request body so the buffer is left
            //    positioned at the next pipelined request. If the
            //    handler didn't read the body and the client sent
            //    `Expect: 100-continue`, the drain will send the
            //    interim 100 Continue first so reverse proxies (nginx)
            //    proceed with body forwarding instead of retrying.
            //    Bounded by `readTimeout` inside the actor.
            if await !conn.isBodyDone() {
                try? await conn.drainBody()
            }
        }
    }

    // MARK: - Helpers (non-isolated)

    @inline(__always)
    private nonisolated static func writeErrorAndClose(
        fd: CInt,
        writeBuffer: inout [UInt8],
        status: StatusCode,
        message: String
    ) {
        let response = errorResponse(status: status, message: message)
        writeBuffer.removeAll(keepingCapacity: true)
        _ = H1Encoder().encodeHead(response, keepAlive: false, into: &writeBuffer)
        // Best-effort, non-blocking: the connection is being torn down
        // regardless, so a truncated error body is acceptable. Must NOT
        // block the loop thread (the socket is non-blocking).
        writeBestEffort(fd: fd, buffer: writeBuffer)
    }

    /// Best-effort non-blocking write for the error/close path. Writes
    /// until the socket accepts no more (`EAGAIN`) or errors; never
    /// awaits and never blocks. The socket is non-blocking, so every
    /// `write(2)` returns immediately.
    @inline(__always)
    private nonisolated static func writeBestEffort(fd: CInt, buffer: [UInt8]) {
        #if canImport(Glibc)
        buffer.withUnsafeBufferPointer { ptr in
            var offset = 0
            while offset < ptr.count {
                let n = Glibc.write(
                    fd, ptr.baseAddress!.advanced(by: offset),
                    ptr.count - offset
                )
                if n > 0 { offset += Int(n); continue }
                if n == 0 { return }
                if errno == EINTR { continue }
                return  // EAGAIN / EPIPE / ... — give up, conn closing
            }
        }
        #endif
    }

    /// Single optimistic `writev(2)` of header + body — one syscall,
    /// zero concatenation (direct port of hyper's vectorised write
    /// path). Returns bytes written (`0...total`) or `-1` on error
    /// (including `EAGAIN` with nothing written). The caller handles
    /// partial results via `writeAll`. On loopback the whole response
    /// fits in the socket buffer, so this returns `total` and the
    /// caller never crosses an await.
    @inline(__always)
    private nonisolated static func writevOnce(
        fd: CInt, header: [UInt8], body: [UInt8]
    ) -> Int {
        #if canImport(Glibc)
        return header.withUnsafeBufferPointer { h in
            body.withUnsafeBufferPointer { b in
                var iovs: [iovec] = [
                    iovec(
                        iov_base: UnsafeMutableRawPointer(mutating: h.baseAddress!),
                        iov_len: h.count
                    ),
                    iovec(
                        iov_base: UnsafeMutableRawPointer(mutating: b.baseAddress!),
                        iov_len: b.count
                    ),
                ]
                return Int(writev(fd, &iovs, 2))
            }
        }
        #else
        return -1
        #endif
    }

    /// Async write of an `ArraySlice<UInt8>` with reactor-backed
    /// backpressure. Performs an optimistic `write(2)`; on `EAGAIN`
    /// arms `EPOLLOUT` via `eventLoop.awaitWritable` — suspending this
    /// Task so the loop can serve other connections — then retries.
    /// Returns `true` iff every byte was written; `false` on error,
    /// hangup, or write-stall timeout (caller must close the connection).
    ///
    /// `ArraySlice` shares its source's storage, so `buffer[range...]`
    /// allocates nothing, and ARC keeps it valid across the await (no
    /// raw-pointer-lifetime hazard). `withUnsafeBytes` is invoked once
    /// per synchronous write attempt and the pointer never escapes an
    /// await.
    private nonisolated static func writeAll(
        fd: CInt,
        _ bytes: ArraySlice<UInt8>,
        eventLoop: PollEventLoop,
        channelId: UInt32,
        writeTimeout: Duration
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
                // Per-EAGAIN-wait bound: a fresh absolute deadline per
                // stall. Detects a reader that stopped reading; a
                // slow-but-steady reader never blocks this long.
                let deadline = ContinuousClock.now + writeTimeout
                if !(await eventLoop.awaitWritable(
                    channelId: channelId, fd: fd, deadline: deadline
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

    /// Get peer socket address via getpeername(2). Called once per
    /// connection (amortised over keep-alive requests).
    @inline(__always)
    private nonisolated static func getPeerAddress(fd: CInt) -> String {
        #if canImport(Glibc)
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let rc = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Glibc.getpeername(fd, sa, &len)
            }
        }
        guard rc == 0 else { return "unknown" }
        var ipBuf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        Glibc.inet_ntop(
            AF_INET, &addr.sin_addr, &ipBuf, socklen_t(INET6_ADDRSTRLEN)
        )
        let port = UInt16(bigEndian: addr.sin_port)
        return "\(String(cString: ipBuf)):\(port)"
        #else
        return "unknown"
        #endif
    }

    @inline(__always)
    private nonisolated static func errorResponse(
        status: StatusCode, message: String
    ) -> Response {
        var headers = HeaderMap()
        headers.insert(.contentType, "text/plain; charset=utf-8")
        headers.insert(.contentLength, String(message.utf8.count))
        return Response(status: status, headers: headers, body: Body(message))
    }
}
