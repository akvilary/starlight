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

    @inlinable
    public init(buffer: ByteBuffer) {
        self.buffer = buffer
    }
}

/// Convenience helpers for the common Phase 2 cases (plaintext, JSON,
/// "hello world"). The real DSL lands in Phase 4.
extension HTTPResponse {
    /// `status`-coded response with `text/plain; charset=utf-8` body.
    /// Use for error responses (404, 400, 500) and short strings.
    public static func plaintext(
        _ body: String,
        status: HTTPStatus = .ok,
        allocator: ByteBufferAllocator = ByteBufferAllocator(),
        keepAlive: Bool = true
    ) -> HTTPResponse {
        var buf = allocator.buffer(capacity: 256 + body.utf8.count)
        let connection = keepAlive ? "keep-alive" : "close"
        buf.writeString("HTTP/1.1 \(status.code) \(status.reasonPhrase)\r\n")
        buf.writeString("Content-Type: text/plain; charset=utf-8\r\n")
        buf.writeString("Content-Length: \(body.utf8.count)\r\n")
        buf.writeString("Connection: \(connection)\r\n")
        buf.writeString("\r\n")
        buf.writeString(body)
        return HTTPResponse(buffer: buf)
    }
}
