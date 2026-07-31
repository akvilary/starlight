//===----------------------------------------------------------------------===//
//
//  IntegrationServer.swift
//  StarlightServerTests
//
//  Minimal single-threaded test server. Binds a TCP listener on
//  `127.0.0.1:0`, accepts connections in a background Task, and for
//  each connection parses HTTP/1.1 requests inline (without the
//  production `H1Conn` actor / `PollEventLoop` stack). Used by
//  integration tests that need to exercise specific wire-level
//  semantics (smuggling vectors, keep-alive, framing).
//
//  IMPORTANT: this server has its own minimal HTTP parser that
//  mirrors the production smuggling guards (bare CR/LF rejection,
//  CL+TE conflict, missing Host, malformed request line). Tests for
//  production streaming semantics (large bodies, chunked streaming,
//  lazy reads) should use the real `serve()` entry point instead —
//  see `ProductionIntegrationTests.swift`.
//
//  The server reads requests synchronously (blocking `read(2)` on a
//  blocking socket). This makes test scenarios deterministic and
//  avoids pulling in `PollEventLoop` machinery (which is exercised
//  separately).
//
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#endif

import Foundation
import HTTP
import HTTPCodec  // H1Encoder for response encoding
import StarlightServer
import Synchronization

/// Minimal single-threaded test server with its own inline parser.
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

        var encoder = H1Encoder()
        // One accumulator buffer per connection — cleared after each
        // request is consumed (keep-alive).
        var buffer: [UInt8] = []

        // Connection loop (keep-alive).
        while true {
            // 1. Read until we have a complete header block (\r\n\r\n).
            var headerEnd: Int? = nil
            while true {
                if let end = findHeaderBlockEnd(in: buffer) {
                    headerEnd = end
                    break
                }
                let more = readChunk(fd: fd)
                if more.isEmpty {
                    // EOF — connection closed by client.
                    return
                }
                buffer.append(contentsOf: more)
                // Header bomb protection — keep tests safe.
                if buffer.count > 64 * 1024 {
                    writeBadRequest(fd: fd, encoder: &encoder)
                    return
                }
            }

            // 2. Parse request line + headers.
            let request: HTTP.Request
            let contentLength: Int
            do {
                (request, contentLength) = try parseRequestHeaders(
                    buffer: buffer, headerEnd: headerEnd!
                )
            } catch {
                writeBadRequest(fd: fd, encoder: &encoder)
                return
            }

            // 3. Read body bytes (CL-bounded only — chunked test
            //    bodies go through production tests).
            var bodyBytes: [UInt8] = []
            if contentLength > 0 {
                // Move header bytes out, keep body bytes.
                let bodyStart = headerEnd!
                buffer.removeFirst(bodyStart)
                while buffer.count < contentLength {
                    let more = readChunk(fd: fd)
                    if more.isEmpty {
                        // EOF before body complete.
                        return
                    }
                    buffer.append(contentsOf: more)
                }
                bodyBytes = Array(buffer.prefix(contentLength))
                buffer.removeFirst(contentLength)
            } else {
                // No body — clear the headers.
                buffer.removeFirst(headerEnd!)
            }

            var reqWithBody = request
            reqWithBody.body = .buffered(bodyBytes)

            // 4. Dispatch to the handler.
            let response = handler(reqWithBody)

            // 5. Encode + write.
            var outBuf: [UInt8] = []
            let head = encoder.encodeHead(
                response, keepAlive: true,
                requestMethod: reqWithBody.method,
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

    /// Write a 400 Bad Request response and close.
    @inline(__always)
    private static func writeBadRequest(fd: CInt, encoder: inout H1Encoder) {
        #if canImport(Glibc)
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

    // MARK: - Inline parser (mirrors production smuggling guards)

    /// Find `\r\n\r\n` end-of-headers. Returns the index after the
    /// final `\n`, or nil.
    private static func findHeaderBlockEnd(in buffer: [UInt8]) -> Int? {
        guard buffer.count >= 4 else { return nil }
        var i = 0
        while i + 4 <= buffer.count {
            if buffer[i] == 0x0D, buffer[i + 1] == 0x0A,
               buffer[i + 2] == 0x0D, buffer[i + 3] == 0x0A {
                return i + 4
            }
            i += 1
        }
        return nil
    }

    /// Parse request line + headers. Throws on malformed input —
    /// smuggling guards are preserved (bare CR/LF, missing Host,
    /// CL+TE conflict, etc.).
    ///
    /// Returns the Request (without body — body is read separately)
    /// plus the parsed Content-Length (0 if absent).
    private static func parseRequestHeaders(
        buffer: [UInt8], headerEnd: Int
    ) throws -> (request: HTTP.Request, contentLength: Int) {
        var pos = 0

        // ── Request line: METHOD SP TARGET SP HTTP/1.x CRLF ──────
        guard let methodEnd = findByte(0x20, in: buffer, from: pos, upto: headerEnd) else {
            throw ParseError.malformed
        }
        let method = Method(String(decoding: buffer[pos..<methodEnd], as: UTF8.self))
        pos = methodEnd + 1
        while pos < headerEnd && buffer[pos] == 0x20 { pos += 1 }
        guard let targetEnd = findByte(0x20, in: buffer, from: pos, upto: headerEnd) else {
            throw ParseError.malformed
        }
        let uri = Uri(bytes: Array(buffer[pos..<targetEnd]))
        pos = targetEnd + 1
        while pos < headerEnd && buffer[pos] == 0x20 { pos += 1 }

        // Version: HTTP/1.x
        guard pos + 10 <= headerEnd,
              buffer[pos] == 0x48, buffer[pos + 1] == 0x54,
              buffer[pos + 2] == 0x54, buffer[pos + 3] == 0x50,
              buffer[pos + 4] == 0x2F,
              buffer[pos + 5] == 0x31,
              buffer[pos + 6] == 0x2E
        else { throw ParseError.malformed }
        let version: Version
        switch buffer[pos + 7] {
        case 0x30: version = .http10
        case 0x31: version = .http11
        default: throw ParseError.malformed
        }
        pos += 8
        guard pos + 1 < headerEnd,
              buffer[pos] == 0x0D, buffer[pos + 1] == 0x0A
        else { throw ParseError.malformed }
        pos += 2

        // ── Headers ─────────────────────────────────────────────
        var headers = HeaderMap()
        var contentLength: Int? = nil
        var hasTransferEncoding = false
        var seenHost = false
        var headerIndex = 0

        while pos < headerEnd - 2 {
            if buffer[pos] == 0x0D && buffer[pos + 1] == 0x0A { break }
            headerIndex += 1
            if headerIndex > 100 { throw ParseError.malformed }

            let nameStart = pos
            while pos < headerEnd && buffer[pos] != 0x3A && buffer[pos] != 0x0D {
                pos += 1
            }
            guard pos < headerEnd, buffer[pos] == 0x3A else {
                throw ParseError.malformed
            }
            let nameBytes = buffer[nameStart..<pos]
            if nameBytes.isEmpty { throw ParseError.malformed }
            let name = HeaderName(lowercasedBytes: nameBytes.map {
                (0x41...0x5A).contains($0) ? $0 + 0x20 : $0
            })
            pos += 1
            while pos < headerEnd && (buffer[pos] == 0x20 || buffer[pos] == 0x09) {
                pos += 1
            }
            // Value: scan until CRLF, reject bare CR/LF.
            let valueStart = pos
            scanLoop: while pos < headerEnd - 1 {
                let b = buffer[pos]
                if b == 0x0D {
                    if buffer[pos + 1] == 0x0A { break scanLoop }
                    throw ParseError.malformed  // bare CR
                }
                if b == 0x0A {
                    throw ParseError.malformed  // bare LF
                }
                pos += 1
            }
            var valueEnd = pos
            while valueEnd > valueStart {
                let prev = buffer[valueEnd - 1]
                if prev == 0x20 || prev == 0x09 { valueEnd -= 1 } else { break }
            }
            let valueBytes = Array(buffer[valueStart..<valueEnd])
            headers.append(name, HeaderValue(bytes: valueBytes))

            // Track framing / host.
            let lowerName = nameBytes.map {
                (0x41...0x5A).contains($0) ? $0 + 0x20 : $0
            }
            if lowerName == Array("content-length".utf8) {
                if let n = Int(String(decoding: valueBytes, as: UTF8.self)), n >= 0 {
                    if let existing = contentLength, existing != n {
                        throw ParseError.malformed  // conflicting CL
                    }
                    contentLength = n
                } else {
                    throw ParseError.malformed
                }
            } else if lowerName == Array("transfer-encoding".utf8) {
                let lower = valueBytes.map {
                    (0x41...0x5A).contains($0) ? $0 + 0x20 : $0
                }
                if lastTokenIsChunked(lower) {
                    hasTransferEncoding = true
                }
            } else if lowerName == Array("host".utf8) {
                seenHost = true
            }

            // Consume CRLF.
            guard pos + 1 < headerEnd,
                  buffer[pos] == 0x0D, buffer[pos + 1] == 0x0A
            else { throw ParseError.malformed }
            pos += 2
        }

        // HTTP/1.1 Host check.
        if version == .http11 && !seenHost {
            throw ParseError.malformed
        }
        // CL + TE conflict.
        if hasTransferEncoding && contentLength != nil {
            throw ParseError.malformed
        }

        // Strip hop-by-hop (handler shouldn't see them).
        headers.entries.removeAll { (n, _) in n.isHopByHop() }

        let request = HTTP.Request(
            method: method,
            uri: uri,
            version: version,
            headers: headers,
            body: .empty
        )
        return (request, contentLength ?? 0)
    }

    private enum ParseError: Error {
        case malformed
    }

    @inline(__always)
    private static func findByte(_ needle: UInt8, in buffer: [UInt8], from start: Int, upto end: Int) -> Int? {
        var i = start
        while i < end {
            if buffer[i] == needle { return i }
            i += 1
        }
        return nil
    }

    /// Check whether the last comma-separated token of a lowercased
    /// Transfer-Encoding value is exactly "chunked".
    @inline(__always)
    private static func lastTokenIsChunked(_ lower: [UInt8]) -> Bool {
        var lastComma: Int? = nil
        for i in 0..<lower.count where lower[i] == 0x2C { lastComma = i }
        let s = (lastComma ?? -1) + 1
        var e = lower.count
        while e > s && (lower[e - 1] == 0x20 || lower[e - 1] == 0x09) { e -= 1 }
        var start = s
        while start < e && (lower[start] == 0x20 || lower[start] == 0x09) { start += 1 }
        let chunked = Array("chunked".utf8)
        guard e - start == chunked.count else { return false }
        for i in 0..<chunked.count where lower[start + i] != chunked[i] { return false }
        return true
    }
    #endif
}
