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
import StarlightTower

/// Per-connection state. Owned by the per-conn Task frame.
struct ConnState: Sendable {
    let fd: CInt
    let channelId: UInt32
    var decoder: H1Decoder
    let encoder: H1Encoder
}

/// One HTTP worker. Bound to a `PollEventLoop` via `unownedExecutor`,
/// owns the listener fd, manages all connections accepted on this loop.
public actor Worker {

    // MARK: - Immutable configuration

    public nonisolated let eventLoop: PollEventLoop
    public nonisolated let listenerFd: CInt
    public nonisolated let router: BoxService<Request<Body>, Response<Body>>
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

    // MARK: - Init

    public init(
        eventLoop: PollEventLoop,
        listenerFd: CInt,
        router: BoxService<Request<Body>, Response<Body>>,
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
    /// callback (loop thread, via assumeIsolated).
    func handleAccept() {
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
        let conn = ConnState(
            fd: fd,
            channelId: channelId,
            decoder: H1Decoder(),
            encoder: H1Encoder()
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
    func connectionClosed() {
        inFlightConns &-= 1
    }

    // MARK: - Per-connection driver (non-isolated)

    /// Drive one connection through its lifetime. Non-isolated so it
    /// can run on the eventLoop Task without going through actor dispatch.
    private nonisolated static func driveConnection(
        eventLoop: PollEventLoop,
        router: BoxService<Request<Body>, Response<Body>>,
        conn initialConn: ConnState,
        readBufferSize: Int
    ) async {
        var conn = initialConn
        let fd = conn.fd
        let channelId = conn.channelId
        defer {
            #if canImport(Glibc)
            _ = Glibc.close(fd)
            #endif
            eventLoop.cancelChannel(channelId)
        }

        // Per-conn read buffer — reused across keep-alive requests.
        let readBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: readBufferSize)
        defer { readBuffer.deallocate() }

        var writeBuffer: [UInt8] = []
        writeBuffer.reserveCapacity(2048)

        connLoop: while true {
            // 1. Async read. Suspends the Task until readable.
            let n = await eventLoop.read(
                channelId: channelId,
                fd: fd,
                into: UnsafeMutableRawBufferPointer(
                    start: UnsafeMutableRawPointer(readBuffer),
                    count: readBufferSize
                )
            )
            if n <= 0 { return }

            // 2. Feed the decoder.
            do {
                let bytes = UnsafeBufferPointer(start: readBuffer, count: n)
                try conn.decoder.feed(bytes)
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
                guard case .complete(let request) = parseResult else {
                    break reqLoop
                }

                let keepAlive = shouldKeepAlive(
                    version: request.version,
                    explicitConnection: request.headers.first(for: .connection)
                )

                let response: Response<Body>
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
                conn.encoder.encode(response, keepAlive: keepAlive, into: &writeBuffer)
                #if canImport(Glibc)
                let written = writeBuffer.withUnsafeBufferPointer { ptr -> Int in
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
                if written < writeBuffer.count { return }
                #endif
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
        H1Encoder().encode(response, keepAlive: false, into: &writeBuffer)
        #if canImport(Glibc)
        _ = writeBuffer.withUnsafeBufferPointer { ptr in
            Glibc.write(fd, ptr.baseAddress!, ptr.count)
        }
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
    ) -> Response<Body> {
        var headers = HeaderMap()
        headers.insert(.contentType, "text/plain; charset=utf-8")
        headers.insert(.contentLength, String(message.utf8.count))
        return Response(status: status, headers: headers, body: Body(message))
    }
}
