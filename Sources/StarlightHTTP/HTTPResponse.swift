//===----------------------------------------------------------------------===//
//
//  HTTPResponse.swift
//  StarlightHTTP
//
//  Minimal HTTP/1.1 response builder for Phase 2. The full ResponseBuilder
//  with `MutableSpan` and vectorized `writev` lands in Phase 3 — for now
//  we serialize into a `ByteBuffer` directly. This is enough to drive
//  end-to-end HTTP benchmarks and validate the parser pipeline.
//
//===----------------------------------------------------------------------===//

import NIOCore
import NIOPosix

/// Closure that, given a parsed request context, produces an HTTP
/// response. The handler runs **synchronously** — directly inline
/// in the connection Task, zero allocation.
public typealias HTTPHandler = @Sendable (borrowing RequestContext) -> HTTPResponse

/// Async variant — same signature but with `async`. Runs inline in
/// the connection Task via `await`, **zero Task-per-request
/// allocation** (the connection Task is the only Task; async
/// handlers are continuations within it, not spawned Tasks).
public typealias AsyncHTTPHandler = @Sendable (borrowing RequestContext) async -> HTTPResponse

/// Dispatch kind for a registered route. Either sync or async.
/// Stored in `Route` so the codec can branch at dispatch time.
public enum HandlerKind: Sendable {
    case sync(HTTPHandler)
    case async(AsyncHTTPHandler)
}

/// A fully-built HTTP/1.1 response, serialized into a `ByteBuffer`.
///
/// Phase 3 will replace this with a `writev`-friendly vector of slices
/// (status-line + headers + body chunks) so that no intermediate buffer
/// is needed at all. For Phase 2 we go through `ByteBuffer` to keep the
/// pipeline simple and verify correctness first.
public struct HTTPResponse: Sendable {
    public let buffer: ByteBuffer

    /// Whether the connection should stay open after this response.
    /// Error responses (400, 404, 413) set this to `false` — the
    /// server closes the TCP connection after writing the response.
    public let keepAlive: Bool

    @inlinable
    public init(buffer: ByteBuffer, keepAlive: Bool = true) {
        self.buffer = buffer
        self.keepAlive = keepAlive
    }
}

/// Convenience helpers for the common Phase 2 cases (plaintext, JSON,
/// "hello world"). The real DSL lands in Phase 4.
extension HTTPResponse {
    /// Shared allocator — `ByteBufferAllocator` is a stateless thread-safe
    /// factory, so one instance serves all responses. Eliminates the
    /// per-call `ByteBufferAllocator()` class allocation that the old
    /// default-parameter pattern caused.
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
        return HTTPResponse(buffer: buf, keepAlive: keepAlive)
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
        return HTTPResponse(buffer: buffer, keepAlive: keepAlive)
    }

    /// Shared response-writing logic. Writes status line, standard
    /// headers, blank line, and body into `buf`.
    @inlinable
    static func writeResponse(
        into buf: inout ByteBuffer,
        body: String,
        status: HTTPStatus,
        keepAlive: Bool
    ) {
        buf.writeString("HTTP/1.1 \(status.code) \(status.reasonPhrase)\r\n")
        buf.writeString("Content-Type: text/plain; charset=utf-8\r\n")
        buf.writeString("Content-Length: \(body.utf8.count)\r\n")
        buf.writeString("Connection: \(keepAlive ? "keep-alive" : "close")\r\n")
        buf.writeString("\r\n")
        buf.writeString(body)
    }
}
