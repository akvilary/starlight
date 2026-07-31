//===----------------------------------------------------------------------===//
//
//  IntegrationClient.swift
//  StarlightServer
//
//  Real-TCP integration test client. Unlike `TestClient` (which calls
//  `Service.call(_:)` directly, bypassing the codec), `IntegrationClient`
//  opens a real TCP socket against a bound listener, sends raw HTTP/1.1
//  bytes, and parses the raw response bytes back.
//
//  This catches the entire pipeline that `TestClient` skips:
//    • `epoll_wait` / `accept4` / `read(2)` / `write(2)` paths
//    • `H1Conn` byte-by-byte parsing (including smuggling vectors)
//    • `H1Encoder` framing (Content-Length, chunked, HEAD/204/304)
//    • keep-alive, pipelining, partial reads, connection lifecycle
//    • `Worker` actor + `PollEventLoop` integration
//
//  Two layers are exposed:
//    • `sendRaw(_:readUntil:)` — the byte-level escape hatch, lets the
//      caller craft malformed requests (smuggling, bare LF, etc).
//    • `request(method:path:version:headers:body:)` — convenience that
//      builds a normalised request and parses the response into a
//      `RawResponse`.
//
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#endif

import Foundation

/// A parsed HTTP/1.1 response, as observed on the wire. Headers are
/// preserved in received order so tests can assert exact framing
/// (Content-Length before Content-Type, duplicate headers, etc).
public struct RawResponse: Sendable {
    /// The status-line version token, e.g. `"HTTP/1.1"`.
    public let version: String
    /// Numeric status code, e.g. `200`.
    public let statusCode: Int
    /// The reason phrase, e.g. `"OK"`. May be empty.
    public let reasonPhrase: String
    /// Headers in received order. Header names preserve original case.
    public let headers: [(name: String, value: String)]
    /// Body bytes. Empty for HEAD responses and status codes that
    /// forbid a body (1xx, 204, 304).
    public let body: [UInt8]

    public init(
        version: String,
        statusCode: Int,
        reasonPhrase: String,
        headers: [(name: String, value: String)],
        body: [UInt8]
    ) {
        self.version = version
        self.statusCode = statusCode
        self.reasonPhrase = reasonPhrase
        self.headers = headers
        self.body = body
    }

    /// Case-insensitive header lookup. Returns the first matching value.
    public func firstHeader(named name: String) -> String? {
        let lower = name.lowercased()
        for (n, v) in headers where n.lowercased() == lower {
            return v
        }
        return nil
    }
}

/// A real-TCP HTTP/1.1 client for integration tests.
///
/// Opens one TCP socket per instance. The socket is blocking from the
/// client side — the server side may still be fully async (epoll-driven
/// `PollEventLoop` + `Worker` actor). After each request the socket
/// stays open until either side closes it or `close()` is called.
///
/// **Lifecycle:** `close()` MUST be called when the test is done with
/// the client; otherwise the file descriptor leaks. Tests typically use
/// `defer { client.close() }` for this.
public final class IntegrationClient: Sendable {
    public let host: String
    public let port: Int
    private let fd: CInt

    /// Connect to `(host, port)`. Throws if the connection cannot be
    /// established.
    public init(host: String = "127.0.0.1", port: Int) throws {
        self.host = host
        self.port = port
        let fd = try Self.connect(host: host, port: port)
        self.fd = fd
    }

    deinit {
        #if canImport(Glibc)
        // Defensive close — `close()` is the documented lifecycle path,
        // but deinit catches the leak case where the caller forgets.
        _ = Glibc.close(fd)
        #endif
    }

    /// Close the underlying socket. Idempotent. After this call the
    /// instance is unusable.
    public func close() {
        #if canImport(Glibc)
        _ = Glibc.close(fd)
        #endif
    }

    // MARK: - Raw byte I/O

    /// Strategy for how long `sendRaw` keeps reading the response.
    public enum ReadStrategy: Sendable {
        /// Read until `Content-Length` bytes have arrived (or until the
        /// connection closes if no Content-Length header is present).
        /// Suitable for normal HTTP/1.1 responses.
        case contentLengthOrClose
        /// Read until the server closes the connection. Suitable for
        /// HTTP/1.0-style responses and tests that explicitly want to
        /// observe close-delimited framing.
        case untilConnectionClose
        /// Read only what is immediately available in the kernel buffer
        /// after a brief sleep. Suitable for tests that want to inspect
        /// a partial response (e.g. server sent headers + first chunk
        /// of a streaming response, then blocked).
        case immediateOnly
    }

    /// Send raw bytes and read the response according to `strategy`.
    /// Returns the raw response bytes (status line + headers + body).
    @discardableResult
    public func sendRaw(
        _ bytes: [UInt8],
        readUntil strategy: ReadStrategy = .contentLengthOrClose
    ) throws -> [UInt8] {
        #if canImport(Glibc)
        try bytes.withUnsafeBufferPointer { ptr in
            var sent = 0
            while sent < ptr.count {
                let n = Glibc.write(fd, ptr.baseAddress!.advanced(by: sent), ptr.count - sent)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw IntegrationError.writeFailed(errno: errno)
                }
                sent += n
            }
        }

        switch strategy {
        case .untilConnectionClose:
            return try readUntilClose()
        case .immediateOnly:
            // Brief sleep so the kernel has time to deliver whatever it
            // has buffered. 10 ms is enough on loopback.
            usleep(10_000)
            return try readAvailable()
        case .contentLengthOrClose:
            let raw = try readUntilHeadersEnd()
            // Parse Content-Length to decide how much more to read.
            let (headerBlockBytes, headerBlock) = try Self.splitHeaders(raw)
            let cl: Int?
            if let clStr = Self.firstHeader(in: headerBlock, named: "Content-Length") {
                cl = Int(clStr)
            } else {
                cl = nil
            }
            let bodySoFar = raw.count - headerBlockBytes
            if let cl, cl > bodySoFar {
                let remaining = cl - bodySoFar
                let more = try readExactly(remaining)
                return raw + more
            } else if cl != nil {
                // Already have the full body (or CL is 0 / smaller than
                // what we read — a server bug, but surface the bytes).
                return raw
            } else {
                // No Content-Length — read until close (HTTP/1.0 style).
                let more = try readUntilClose()
                return raw + more
            }
        }
        #else
        throw IntegrationError.unsupportedPlatform
        #endif
    }

    // MARK: - Convenience HTTP request

    /// Build a normalised HTTP/1.1 request, send it, parse the response.
    public func request(
        method: String = "GET",
        path: String = "/",
        version: String = "HTTP/1.1",
        headers: [(name: String, value: String)] = [],
        body: [UInt8] = []
    ) throws -> RawResponse {
        let requestBytes = Self.buildRequest(
            method: method, path: path, version: version,
            headers: headers, body: body
        )
        let responseBytes = try sendRaw(requestBytes)
        return try Self.parseResponse(responseBytes)
    }

    // MARK: - Internals: socket I/O

    #if canImport(Glibc)
    /// Read from the socket until it closes (returns 0). Returns all
    /// accumulated bytes.
    private func readUntilClose() throws -> [UInt8] {
        var out: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = buf.withUnsafeMutableBufferPointer { ptr in
                Glibc.read(fd, ptr.baseAddress, ptr.count)
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw IntegrationError.readFailed(errno: errno)
            }
            if n == 0 { return out }
            out.append(contentsOf: buf.prefix(n))
        }
    }

    /// Read whatever bytes are immediately available in the kernel
    /// buffer. Returns immediately if nothing is buffered yet.
    private func readAvailable() throws -> [UInt8] {
        var out: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = buf.withUnsafeMutableBufferPointer { ptr in
                Glibc.read(fd, ptr.baseAddress, ptr.count)
            }
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return out }
                throw IntegrationError.readFailed(errno: errno)
            }
            if n == 0 { return out }
            out.append(contentsOf: buf.prefix(n))
        }
    }

    /// Read exactly `count` bytes from the socket. Blocks until the
    /// full count is available or the connection closes.
    private func readExactly(_ count: Int) throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(count)
        var buf = [UInt8](repeating: 0, count: Swift.min(count, 4096))
        while out.count < count {
            let want = Swift.min(buf.count, count - out.count)
            let n = buf.withUnsafeMutableBufferPointer { ptr in
                Glibc.read(fd, ptr.baseAddress, want)
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw IntegrationError.readFailed(errno: errno)
            }
            if n == 0 {
                // Server closed before sending the promised bytes.
                return out
            }
            out.append(contentsOf: buf.prefix(n))
        }
        return out
    }

    /// Read until end of headers (`\r\n\r\n`). Returns all bytes seen
    /// (including the headers themselves).
    private func readUntilHeadersEnd() throws -> [UInt8] {
        var out: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 1)
        while true {
            let n = buf.withUnsafeMutableBufferPointer { ptr in
                Glibc.read(fd, ptr.baseAddress, 1)
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw IntegrationError.readFailed(errno: errno)
            }
            if n == 0 {
                // Connection closed before headers end.
                return out
            }
            out.append(buf[0])
            // Check for `\r\n\r\n`.
            if out.count >= 4 {
                let i = out.count - 4
                if out[i] == 0x0D, out[i + 1] == 0x0A,
                   out[i + 2] == 0x0D, out[i + 3] == 0x0A {
                    return out
                }
            }
        }
    }
    #endif

    // MARK: - Internals: parsing

    /// Split raw bytes (status line + headers + maybe start of body)
    /// into (header-block byte count, header lines array).
    /// `header-block byte count` includes the trailing `\r\n\r\n`.
    static func splitHeaders(_ raw: [UInt8]) throws -> (Int, [(String, String)]) {
        // Find `\r\n\r\n`.
        var sepIdx: Int? = nil
        for i in 0..<(raw.count - 3) where i + 3 < raw.count {
            if raw[i] == 0x0D, raw[i + 1] == 0x0A,
               raw[i + 2] == 0x0D, raw[i + 3] == 0x0A {
                sepIdx = i
                break
            }
        }
        guard let sep = sepIdx else {
            throw IntegrationError.malformedResponse(reason: "no \\r\\n\\r\\n header terminator")
        }

        // Header block is raw[0..<sep+4]. Split into lines on `\r\n`.
        let blockEnd = sep + 4
        var headers: [(String, String)] = []
        var lineStart = 0
        // First line is the status line — skip it.
        // Find end of first line.
        var i = 0
        while i < blockEnd - 1 {
            if raw[i] == 0x0D, raw[i + 1] == 0x0A { break }
            i += 1
        }
        lineStart = i + 2

        while lineStart < sep {
            var lineEnd = lineStart
            while lineEnd < sep - 1 {
                if raw[lineEnd] == 0x0D, raw[lineEnd + 1] == 0x0A { break }
                lineEnd += 1
            }
            // Parse `Name: Value`.
            let line = raw[lineStart..<lineEnd]
            if let colon = line.firstIndex(of: 0x3A) {
                let name = String(decoding: raw[lineStart..<colon], as: UTF8.self)
                // Skip `:` and one optional leading space.
                var valueStart = colon + 1
                if valueStart < lineEnd, raw[valueStart] == 0x20 {
                    valueStart += 1
                }
                let value = String(decoding: raw[valueStart..<lineEnd], as: UTF8.self)
                headers.append((name, value))
            }
            lineStart = lineEnd + 2
        }

        return (blockEnd, headers)
    }

    /// Case-insensitive header lookup against an unsorted list.
    static func firstHeader(in headers: [(String, String)], named name: String) -> String? {
        let lower = name.lowercased()
        for (n, v) in headers where n.lowercased() == lower {
            return v
        }
        return nil
    }

    /// Parse raw response bytes (status line + headers + body) into
    /// a `RawResponse`. Body extraction stops at the first header-block
    /// terminator `\r\n\r\n`; the caller is responsible for reading
    /// additional body bytes (handled in `sendRaw`).
    public static func parseResponse(_ raw: [UInt8]) throws -> RawResponse {
        let (blockEnd, headers) = try splitHeaders(raw)

        // First line: `HTTP/x.y SP code SP reason\r\n`.
        var lineEnd = 0
        while lineEnd < raw.count - 1 {
            if raw[lineEnd] == 0x0D, raw[lineEnd + 1] == 0x0A { break }
            lineEnd += 1
        }
        let statusLine = String(decoding: raw[0..<lineEnd], as: UTF8.self)
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2 else {
            throw IntegrationError.malformedResponse(reason: "bad status line: \(statusLine)")
        }
        let version = String(parts[0])
        guard let code = Int(parts[1]) else {
            throw IntegrationError.malformedResponse(reason: "bad status code: \(parts[1])")
        }
        let reason = parts.count >= 3 ? String(parts[2]) : ""

        // Body is whatever raw bytes follow the header block.
        // The caller may have asked for more bytes; what we have here
        // is whatever was in the same `read` window.
        let body = Array(raw[blockEnd...])

        return RawResponse(
            version: version,
            statusCode: code,
            reasonPhrase: reason,
            headers: headers,
            body: body
        )
    }

    /// Build a normalised HTTP/1.1 request byte sequence.
    public static func buildRequest(
        method: String,
        path: String,
        version: String,
        headers: [(name: String, value: String)],
        body: [UInt8]
    ) -> [UInt8] {
        var out: [UInt8] = []
        out.append(contentsOf: Array("\(method) \(path) \(version)\r\n".utf8))
        // Auto-add Host if the caller didn't supply one. HTTP/1.1
        // mandates it (RFC 9112 §3.2), and the codec now enforces this.
        let hasHost = headers.contains { $0.name.lowercased() == "host" }
        if !hasHost {
            out.append(contentsOf: Array("Host: localhost\r\n".utf8))
        }
        for (name, value) in headers {
            out.append(contentsOf: Array("\(name): \(value)\r\n".utf8))
        }
        out.append(contentsOf: [0x0D, 0x0A])  // headers terminator
        out.append(contentsOf: body)
        return out
    }

    // MARK: - Internals: connect

    #if canImport(Glibc)
    private static func connect(host: String, port: Int) throws -> CInt {
        let fd = Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        if fd < 0 {
            throw IntegrationError.socketFailed(errno: errno)
        }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        if Glibc.inet_pton(AF_INET, host, &addr.sin_addr) <= 0 {
            _ = Glibc.close(fd)
            throw IntegrationError.badHost(host)
        }
        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Glibc.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc < 0 {
            let err = errno
            _ = Glibc.close(fd)
            throw IntegrationError.connectFailed(host: host, port: port, errno: err)
        }
        return fd
    }
    #endif
}

/// Errors thrown by `IntegrationClient`.
public enum IntegrationError: Error, Sendable, Equatable {
    case socketFailed(errno: Int32)
    case connectFailed(host: String, port: Int, errno: Int32)
    case badHost(String)
    case writeFailed(errno: Int32)
    case readFailed(errno: Int32)
    case malformedResponse(reason: String)
    case unsupportedPlatform

    public var description: String {
        switch self {
        case .socketFailed(let e): return "socket() failed: \(e)"
        case .connectFailed(let h, let p, let e): return "connect(\(h):\(p)) failed: \(e)"
        case .badHost(let h): return "bad host: \(h)"
        case .writeFailed(let e): return "write() failed: \(e)"
        case .readFailed(let e): return "read() failed: \(e)"
        case .malformedResponse(let r): return "malformed response: \(r)"
        case .unsupportedPlatform: return "unsupported platform (Linux only)"
        }
    }
}
