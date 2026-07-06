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
    /// 200 OK with `text/plain; charset=utf-8` body.
    public static func plaintext(
        _ body: String,
        allocator: ByteBufferAllocator = ByteBufferAllocator(),
        keepAlive: Bool = true
    ) -> HTTPResponse {
        var buf = allocator.buffer(capacity: 256 + body.utf8.count)
        let connection = keepAlive ? "keep-alive" : "close"
        buf.writeString("HTTP/1.1 200 OK\r\n")
        buf.writeString("Content-Type: text/plain; charset=utf-8\r\n")
        buf.writeString("Content-Length: \(body.utf8.count)\r\n")
        buf.writeString("Connection: \(connection)\r\n")
        buf.writeString("\r\n")
        buf.writeString(body)
        return HTTPResponse(buffer: buf)
    }
}
