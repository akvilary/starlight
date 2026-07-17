//===----------------------------------------------------------------------===//
//
//  HTTPResponse.swift
//  StarlightHTTP
//
//  HTTP/1.1 response builder with zero-interpolation header
//  serialization and writev-friendly multi-buffer output.
//
//  ─── Zero-interpolation design ─────────────────────────────────────────
//
//  Every `writeString("HTTP/1.1 \(code) \(reason)\r\n")` in the old
//  code created a heap-allocated interpolated String (> 15 bytes →
//  not a SmallString). At 240K req/s with 5 interpolated lines per
//  response, that was ~1.2M heap alloc/dealloc per second.
//
//  The new `writeResponse` uses `writeStaticString` (compile-time
//  constant, zero allocation) for all static header text and writes
//  Content-Length digits directly — no interpolated String is ever
//  constructed on the hot path.
//
//  ─── writev (vectorized I/O) ────────────────────────────────────────────
//
//  When `bodyBuffer != nil`, the response carries a separate header
//  ByteBuffer and body ByteBuffer. The server writes both via
//  `outbound.write(contentsOf:)`, which NIO coalesces into a single
//  `writev()` syscall (see PendingWritesManager.currentBestWriteMechanism).
//
//===----------------------------------------------------------------------===//

import NIOCore
import NIOPosix

/// Closure that, given a parsed request context, produces an HTTP
/// response. The handler runs **synchronously** — directly inline
/// in the connection Task, zero allocation.
///
/// The handler is allowed to `throw`. A thrown error propagates up
/// through `Router.handle(_:)` (which is `async throws`) and is
/// caught by `HTTP1Codec`, which synthesises a `500 Internal Server
/// Error` response. To customise the error response, register an
/// error-handling middleware that wraps the handler in `do/catch`.
public typealias HTTPHandler = @Sendable (borrowing RequestContext) throws -> HTTPResponse

/// Async variant — same signature but with `async`. Runs inline in
/// the connection Task via `await`, **zero Task-per-request
/// allocation** (the connection Task is the only Task; async
/// handlers are continuations within it, not spawned Tasks).
///
/// See `HTTPHandler` for the `throws` semantics.
public typealias AsyncHTTPHandler = @Sendable (borrowing RequestContext) async throws -> HTTPResponse

/// Dispatch kind for a registered route. Either sync or async.
/// Stored in `Route` so the codec can branch at dispatch time.
public enum HandlerKind: Sendable {
    case sync(HTTPHandler)
    case async(AsyncHTTPHandler)
}

/// A fully-built HTTP/1.1 response.
///
/// In the single-buffer case (`bodyBuffer == nil`), `buffer` holds
/// the complete serialized response (status line + headers + body).
/// In the multi-buffer case (`bodyBuffer != nil`), `headerBuffer` holds
/// only the header section and `bodyBuffer` holds the body — the
/// server writes both via a single `writev()` syscall.
public struct HTTPResponse: Sendable {
    /// Header buffer (or full response when `bodyBuffer` is nil).
    public let headerBuffer: ByteBuffer

    /// Optional separate body buffer for writev. When non-nil,
    /// `headerBuffer` contains only the response headers and
    /// `bodyBuffer` holds the body — the server writes both via a
    /// single `writev()` syscall (NIO coalesces ≥2 ByteBuffers on
    /// flush).
    ///
    /// `Optional<ByteBuffer>` is the same size as `ByteBuffer` (23 B)
    /// thanks to Swift's spare-bit optimization, so the total struct
    /// is 48 B — fits in one cache line.
    public let bodyBuffer: ByteBuffer?

    /// Whether the connection should stay open after this response.
    /// Error responses (400, 404, 413) set this to `false` — the
    /// server closes the TCP connection after writing the response.
    public let keepAlive: Bool

    /// Single-buffer response — `headerBuffer` contains the full
    /// response (status line + headers + body).
    @inlinable
    public init(headerBuffer: ByteBuffer, keepAlive: Bool = true) {
        self.headerBuffer = headerBuffer
        self.bodyBuffer = nil
        self.keepAlive = keepAlive
    }

    /// Multi-buffer response — `header` contains status line +
    /// headers, `body` contains the body. The server writes both
    /// via `writev()`.
    @inlinable
    public init(header: ByteBuffer, body: ByteBuffer, keepAlive: Bool = true) {
        self.headerBuffer = header
        self.bodyBuffer = body
        self.keepAlive = keepAlive
    }
}

/// Convenience helpers for the common cases (plaintext, JSON,
/// "hello world").
extension HTTPResponse {
    /// Shared allocator — one instance serves all responses.
    @usableFromInline
    internal static let sharedAllocator = ByteBufferAllocator()

    /// `status`-coded response with `text/plain; charset=utf-8` body.
    /// Use for error responses (404, 400, 500) and short strings.
    ///
    /// - Note: Allocates a new `ByteBuffer` per call. For the hot
    ///   path, use `plaintext(_:status:keepAlive:into:)` with a
    ///   reusable buffer to eliminate per-response allocation.
    public static func plaintext(
        _ body: String,
        status: HTTPStatus = .ok,
        keepAlive: Bool = true
    ) -> HTTPResponse {
        var buf = sharedAllocator.buffer(capacity: 256 + body.utf8.count)
        writeResponse(into: &buf, body: body, status: status, keepAlive: keepAlive)
        return HTTPResponse(headerBuffer: buf, keepAlive: keepAlive)
    }

    /// Zero-allocation response builder that writes into a reusable
    /// buffer. The caller owns the buffer (typically per-connection)
    /// and clears it between requests. `ByteBuffer` is COW, so the
    /// returned `HTTPResponse` shares storage with `buffer` until the
    /// next write triggers COW — no memcpy.
    ///
    /// Usage:
    /// ```swift
    /// // In a handler, using the codec's per-connection buffer:
    /// return HTTPResponse.plaintext("ok", into: &ctx.responseBuffer)
    /// ```
    public static func plaintext(
        _ body: String,
        status: HTTPStatus = .ok,
        keepAlive: Bool = true,
        into buffer: inout ByteBuffer
    ) -> HTTPResponse {
        buffer.clear()
        writeResponse(into: &buffer, body: body, status: status, keepAlive: keepAlive)
        return HTTPResponse(headerBuffer: buffer, keepAlive: keepAlive)
    }

    // MARK: - Zero-interpolation response serialization

    /// Shared response-writing logic. Writes status line, standard
    /// headers, blank line, and body into `buf`.
    ///
    /// Uses `writeStaticString` for all constant header text — zero
    /// String interpolation, zero heap allocation on the hot path.
    /// Content-Length is written as a SmallString (`String(count)`
    /// for typical 1–4 digit values is ≤ 15 bytes, stored inline).
    @inlinable
    static func writeResponse(
        into buf: inout ByteBuffer,
        body: String,
        status: HTTPStatus,
        keepAlive: Bool
    ) {
        Self.writeStatusLine(status, into: &buf)
        buf.writeStaticString("Content-Type: text/plain; charset=utf-8\r\n")
        buf.writeStaticString("Content-Length: ")
        buf.writeString(String(body.utf8.count))
        if keepAlive {
            buf.writeStaticString("\r\nConnection: keep-alive\r\n\r\n")
        } else {
            buf.writeStaticString("\r\nConnection: close\r\n\r\n")
        }
        buf.writeString(body)
    }

    /// Write the HTTP/1.1 status line. Common codes use
    /// `writeStaticString` (compile-time constant — zero allocation).
    /// Uncommon codes fall back to `writeString` with interpolation.
    @usableFromInline
    @inline(__always)
    static func writeStatusLine(_ status: HTTPStatus, into buf: inout ByteBuffer) {
        switch status.code {
        case 200: buf.writeStaticString("HTTP/1.1 200 OK\r\n")
        case 201: buf.writeStaticString("HTTP/1.1 201 Created\r\n")
        case 204: buf.writeStaticString("HTTP/1.1 204 No Content\r\n")
        case 301: buf.writeStaticString("HTTP/1.1 301 Moved Permanently\r\n")
        case 302: buf.writeStaticString("HTTP/1.1 302 Found\r\n")
        case 304: buf.writeStaticString("HTTP/1.1 304 Not Modified\r\n")
        case 400: buf.writeStaticString("HTTP/1.1 400 Bad Request\r\n")
        case 401: buf.writeStaticString("HTTP/1.1 401 Unauthorized\r\n")
        case 403: buf.writeStaticString("HTTP/1.1 403 Forbidden\r\n")
        case 404: buf.writeStaticString("HTTP/1.1 404 Not Found\r\n")
        case 405: buf.writeStaticString("HTTP/1.1 405 Method Not Allowed\r\n")
        case 408: buf.writeStaticString("HTTP/1.1 408 Request Timeout\r\n")
        case 409: buf.writeStaticString("HTTP/1.1 409 Conflict\r\n")
        case 413: buf.writeStaticString("HTTP/1.1 413 Payload Too Large\r\n")
        case 414: buf.writeStaticString("HTTP/1.1 414 URI Too Long\r\n")
        case 429: buf.writeStaticString("HTTP/1.1 429 Too Many Requests\r\n")
        case 500: buf.writeStaticString("HTTP/1.1 500 Internal Server Error\r\n")
        case 501: buf.writeStaticString("HTTP/1.1 501 Not Implemented\r\n")
        case 502: buf.writeStaticString("HTTP/1.1 502 Bad Gateway\r\n")
        case 503: buf.writeStaticString("HTTP/1.1 503 Service Unavailable\r\n")
        case 504: buf.writeStaticString("HTTP/1.1 504 Gateway Timeout\r\n")
        default:
            buf.writeString("HTTP/1.1 \(status.code) \(status.reasonPhrase)\r\n")
        }
    }
}
