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
import Hyper
import StarlightPoll
import StarlightExtractors   // ConnectInfo
import StarlightTower

/// Per-connection state. Owned by the per-conn Task frame.
struct ConnState: Sendable {
    let fd: CInt
    let channelId: UInt32
    var decoder: H1Decoder
    let encoder: H1Encoder
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
            if fd < 0 { break }  // EAGAIN — drained
            acceptConnection(fd: fd)
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
            decoder: H1Decoder(),
            encoder: H1Encoder(),
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
    private nonisolated static func driveConnection(
        eventLoop: PollEventLoop,
        router: BoxService<Request, Response>,
        conn initialConn: ConnState,
        readBufferSize: Int
    ) async {
        var conn = initialConn
        let fd = conn.fd
        let channelId = conn.channelId
        let peerAddress = conn.peerAddress
        defer {
            #if canImport(Glibc)
            _ = Glibc.close(fd)
            #endif
            eventLoop.cancelChannel(channelId)
        }

        // Per-conn write buffer — reused for response encoding.
        var writeBuffer: [UInt8] = []
        writeBuffer.reserveCapacity(2048)

        connLoop: while true {
            // 1. Async read — eventLoop reads into its internal buffer.
            //    No external buffer pointer crosses the await boundary.
            //    Eliminates @unchecked on H1Decoder + ConnState.
            let n = await eventLoop.read(channelId: channelId, fd: fd)
            if n <= 0 { return }

            // 2. Feed decoder — copy ~100 bytes from eventLoop's buffer
            //    into decoder's [UInt8]. One memcpy (~10ns).
            let readView = eventLoop.getReadView(channelId: channelId, count: n)
            do {
                try conn.decoder.feed(readView)
            } catch {
                writeErrorAndClose(
                    fd: fd, writeBuffer: &writeBuffer,
                    status: .badRequest, message: "Bad Request: \(error)"
                )
                return
            }

            // 3. Parse + dispatch all complete requests from this read.
            reqLoop: while true {
                let parseResult: DecodeResult
                do {
                    parseResult = try conn.decoder.decode()
                } catch {
                    writeErrorAndClose(
                        fd: fd, writeBuffer: &writeBuffer,
                        status: .badRequest, message: "Bad Request: \(error)"
                    )
                    return
                }
                guard case .complete(var request) = parseResult else {
                    break reqLoop
                }

                // B1 FIX: populate ConnectInfo for extractors + RateLimitLayer.
                request.extensions.insert(ConnectInfo(peerAddress: peerAddress))

                let keepAlive = shouldKeepAlive(
                    version: request.version,
                    explicitConnection: request.headers.first(for: .connection)
                )

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

                writeBuffer.removeAll(keepingCapacity: true)
                let head = conn.encoder.encodeHead(
                    response, keepAlive: keepAlive, into: &writeBuffer
                )
                // Write header (+ body via writev) in one syscall.
                switch head {
                case .noBody:
                    _ = writeAll(fd: fd, buffer: writeBuffer)
                case .buffered:
                    if case .buffered(let bodyBytes) = response.body, !bodyBytes.isEmpty {
                        _ = writevHeaderBody(fd: fd, header: writeBuffer, body: bodyBytes)
                    } else {
                        _ = writeAll(fd: fd, buffer: writeBuffer)
                    }
                case .stream:
                    // Write header first, then stream chunks.
                    _ = writeAll(fd: fd, buffer: writeBuffer)
                    do {
                        for try await chunk in response.body.dataStream() {
                            writeBuffer.removeAll(keepingCapacity: true)
                            conn.encoder.encodeChunk(chunk, into: &writeBuffer)
                            let written = writeAll(fd: fd, buffer: writeBuffer)
                            if written < writeBuffer.count { return }
                        }
                    } catch { return }
                    writeBuffer.removeAll(keepingCapacity: true)
                    conn.encoder.encodeEndOfChunks(into: &writeBuffer)
                    _ = writeAll(fd: fd, buffer: writeBuffer)
                }
                if !keepAlive { return }
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
        _ = writeAll(fd: fd, buffer: writeBuffer)
    }

    /// Sync `write(2)` loop that handles partial writes.
    @inline(__always)
    private nonisolated static func writeAll(fd: CInt, buffer: [UInt8]) -> Int {
        #if canImport(Glibc)
        return buffer.withUnsafeBufferPointer { ptr -> Int in
            var remaining = ptr.count
            var offset = 0
            while remaining > 0 {
                let n = Glibc.write(
                    fd, ptr.baseAddress!.advanced(by: offset), remaining
                )
                if n <= 0 { break }
                remaining -= n
                offset += n
            }
            return offset
        }
        #else
        return 0
        #endif
    }

    /// Write header + body via `writev(2)` — one syscall, zero
    /// concatenation. Direct port of hyper's vectorised write path.
    ///
    /// Falls back to sequential writes if writev returns partial.
    @inline(__always)
    private nonisolated static func writevHeaderBody(
        fd: CInt, header: [UInt8], body: [UInt8]
    ) -> Int {
        #if canImport(Glibc)
        return header.withUnsafeBufferPointer { hPtr in
            body.withUnsafeBufferPointer { bPtr in
                var iovs: [iovec] = [
                    iovec(
                        iov_base: UnsafeMutableRawPointer(mutating: hPtr.baseAddress!),
                        iov_len: hPtr.count
                    ),
                    iovec(
                        iov_base: UnsafeMutableRawPointer(mutating: bPtr.baseAddress!),
                        iov_len: bPtr.count
                    ),
                ]
                let totalExpected = hPtr.count + bPtr.count
                let n = writev(fd, &iovs, 2)
                if n >= totalExpected {
                    return n  // everything written in one syscall
                }
                if n <= 0 {
                    return 0  // error
                }
                // Partial write — fall back to individual writes for
                // the remaining bytes. Rare for small responses.
                var written = n
                var headerConsumed = min(n, hPtr.count)
                let bodyConsumed = max(0, n - hPtr.count)
                if headerConsumed < hPtr.count {
                    let remaining = hPtr.count - headerConsumed
                    let w = Glibc.write(fd, hPtr.baseAddress!.advanced(by: headerConsumed), remaining)
                    written += max(0, w)
                }
                if bodyConsumed < bPtr.count {
                    let remaining = bPtr.count - bodyConsumed
                    let w = Glibc.write(fd, bPtr.baseAddress!.advanced(by: bodyConsumed), remaining)
                    written += max(0, w)
                }
                return written
            }
        }
        #else
        return 0
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
    private nonisolated static func shouldKeepAlive(
        version: Version,
        explicitConnection: HeaderValue?
    ) -> Bool {
        if let conn = explicitConnection {
            let lower = String(decoding: conn.bytes, as: UTF8.self).lowercased()
            if lower.contains("close") { return false }
            if lower.contains("keep-alive") { return true }
        }
        return version == .http11
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
