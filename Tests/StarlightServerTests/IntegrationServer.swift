//===----------------------------------------------------------------------===//
//
//  IntegrationServer.swift
//  StarlightServerTests
//
//  Minimal single-threaded test server. Binds a TCP listener on
//  `127.0.0.1:0`, accepts connections in a background Task, and for
//  each connection drives the H1 codec directly against a user-
//  supplied `Service`-shaped closure. Intentionally does NOT use the
//  production `Worker` actor / `PollEventLoop` stack — the point of
//  integration tests is to exercise the codec + protocol semantics,
//  not the I/O backend.
//
//  The server reads requests synchronously (blocking `read(2)` on a
//  blocking socket). This makes test scenarios deterministic and
//  avoids pulling in `PollEventLoop` machinery (which is exercised
//  separately by `StarlightPollTests`).
//
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#endif

import Foundation
import HTTP
import HTTPCodec
import StarlightServer
import Synchronization

/// Minimal single-threaded test server.
///
/// Spawns one background `Task` per `start(...)` invocation. Each
/// accepted connection is handled synchronously in that Task. Tests
/// connect via `IntegrationClient` to the bound port.
final class IntegrationServer {
    /// The actual port the kernel assigned. Available after `init`.
    let port: Int

    private let listenerFd: CInt
    /// Process-wide stop flag for the accept loop. Atomic so the
    /// acceptor Task can read it without holding a lock around `accept()`.
    /// Wrapped in a class because `Atomic<Bool>` is noncopyable and
    /// therefore cannot be captured into a `Task.detached` closure
    /// directly.
    private let stoppedRef = StopFlag()

    /// Class wrapper around an `Atomic<Bool>` — copyable, Sendable,
    /// lets us share a single stop flag between the IntegrationServer
    /// instance and the detached acceptor Task.
    private final class StopFlag: Sendable {
        let value = Atomic<Bool>(false)
    }

    /// Spawn the server. The `handler` closure is called for each
    /// parsed request; its `Response` is encoded and written back.
    /// Connections are keep-alive: the loop reads another request
    /// after each response until the client closes or sends malformed
    /// input.
    init(handler: @escaping @Sendable (HTTP.Request) -> HTTP.Response) throws {
        #if canImport(Glibc)
        let fd = Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        if fd < 0 { throw IntegrationError.socketFailed(errno: errno) }

        // SO_REUSEADDR so subsequent test runs can rebind immediately.
        var yes: Int32 = 1
        _ = Glibc.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(0).bigEndian  // bind to port 0 — kernel picks
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian  // 127.0.0.1

        let bindRc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Glibc.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bindRc < 0 {
            let e = errno; _ = Glibc.close(fd)
            throw IntegrationError.connectFailed(host: "127.0.0.1", port: 0, errno: e)
        }

        if Glibc.listen(fd, 16) < 0 {
            let e = errno; _ = Glibc.close(fd)
            throw IntegrationError.connectFailed(host: "127.0.0.1", port: 0, errno: e)
        }

        // Discover the actual port.
        var bound = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Glibc.getsockname(fd, sa, &boundLen)
            }
        }
        self.port = Int(UInt16(bigEndian: bound.sin_port))
        self.listenerFd = fd
        // Hand off the listen fd to the static accept loop. The fd is
        // now owned by the accept task until it observes `stopped.value == true`
        // (set by `stop()`); the deinit does NOT close the listener for
        // that reason.
        let stopRef = stoppedRef
        Task.detached {
            IntegrationServer.acceptLoop(listenerFd: fd, stopRef: stopRef, handler: handler)
        }
        #else
        throw IntegrationError.unsupportedPlatform
        #endif
    }

    deinit {
        // Don't close listenerFd here — the acceptor Task owns it once
        // started. `stop()` closes it and sets the flag.
    }

    /// Stop accepting new connections. Closes the listener fd, which
    // causes any in-flight `accept()` to return EBADF and exit the loop.
    func stop() {
        stoppedRef.value.store(true, ordering: .releasing)
        #if canImport(Glibc)
        _ = Glibc.close(listenerFd)
        #endif
    }

    // MARK: - Internals

    #if canImport(Glibc)
    /// Free acceptor function. Takes the listener fd and a process-wide
    /// stop flag by reference. Closure captures neither `self` nor any
    /// instance state — `sending`-safe for `Task.detached`.
    private static func acceptLoop(
        listenerFd: CInt,
        stopRef: StopFlag,
        handler: @Sendable @escaping (HTTP.Request) -> HTTP.Response
    ) {
        while !stopRef.value.load(ordering: .acquiring) {
            let clientFd = Glibc.accept(listenerFd, nil, nil)
            if clientFd < 0 {
                if errno == EINTR { continue }
                // EBADF after stop() — exit silently.
                return
            }
            // Set SO_RCVTIMEO/SO_SNDTIMEO so a misbehaving client can't
            // hang the test forever. 500 ms — short enough to keep the
            // full test suite under a few seconds even when smuggling
            // tests deliberately leave the connection open.
            var tv = timeval(tv_sec: 0, tv_usec: 500_000)
            _ = Glibc.setsockopt(clientFd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            _ = Glibc.setsockopt(clientFd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

            // Handle one connection synchronously in the accept loop.
            // This means the server processes one connection at a time,
            // which is fine for tests — keeps the process lifecycle
            // simple (no detached Task pile-up preventing the test
            // runner from exiting).
            Self.handleConnection(fd: clientFd, handler: handler)
        }
    }

    /// Free function (no `self` capture) so it can be safely `sending`-
    /// passed into a `Task.detached` under `NonisolatedNonsendingByDefault`.
    private static func handleConnection(
        fd: CInt,
        handler: @Sendable (HTTP.Request) -> HTTP.Response
    ) {
        #if canImport(Glibc)
        defer { _ = Glibc.close(fd) }

        var decoder = H1Decoder()
        var encoder = H1Encoder()
        var readBuffer: [UInt8] = []

        // Connection loop (keep-alive).
        while true {
            // Decode whatever we have buffered; if more bytes are
            // needed, read from the socket and try again.
            var request: HTTP.Request? = nil
            while true {
                let result: DecodeResult
                do {
                    result = try decoder.decode()
                } catch {
                    // Malformed request — write 400 if we haven't sent
                    // anything on this connection yet, then close.
                    let resp = HTTP.Response(
                        status: .badRequest,
                        headers: HeaderMap(),
                        body: .buffered(Array("Bad Request".utf8))
                    )
                    var buf: [UInt8] = []
                    _ = encoder.encodeHead(resp, keepAlive: false, into: &buf)
                    _ = buf.withUnsafeBufferPointer { ptr in
                        Glibc.write(fd, ptr.baseAddress, ptr.count)
                    }
                    return
                }

                if case .complete(let req) = result {
                    request = req
                    break
                }

                // .needsMore — feed more bytes.
                let more = readChunk(fd: fd)
                if more.isEmpty {
                    // EOF — connection closed by client.
                    return
                }
                readBuffer.append(contentsOf: more)
                do { try decoder.feed(readBuffer) } catch {
                    return
                }
                readBuffer.removeAll(keepingCapacity: true)
            }

            guard let req = request else { return }

            // Dispatch to the handler.
            let response = handler(req)

            // Encode + write.
            var outBuf: [UInt8] = []
            let head = encoder.encodeHead(
                response, keepAlive: true,
                requestMethod: req.method,
                into: &outBuf
            )
            if case .buffered = head {
                if case .buffered(let bytes) = response.body, !bytes.isEmpty {
                    outBuf.append(contentsOf: bytes)
                }
            }
            if outBuf.withUnsafeBufferPointer({ ptr -> Int in
                var sent = 0
                while sent < ptr.count {
                    let n = Glibc.write(fd, ptr.baseAddress!.advanced(by: sent), ptr.count - sent)
                    if n < 0 {
                        if errno == EINTR { continue }
                        return -1
                    }
                    sent += n
                }
                return sent
            }) < 0 {
                return
            }

            // Check keep-alive from the response Connection header.
            let connHeaderValue = response.headers.first(for: .connection)?.description.lowercased() ?? ""
            if connHeaderValue.contains("close") {
                return
            }
        }
        #endif
    }

    /// Blocking read of up to 4 KB from `fd`. Free function — no
    /// `self` capture. Returns the bytes read (empty array on EOF or
    /// error).
    private static func readChunk(fd: CInt) -> [UInt8] {
        #if canImport(Glibc)
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = buf.withUnsafeMutableBufferPointer { ptr in
            Glibc.read(fd, ptr.baseAddress, ptr.count)
        }
        if n <= 0 { return [] }
        return Array(buf.prefix(n))
        #else
        return []
        #endif
    }
    #endif
}
