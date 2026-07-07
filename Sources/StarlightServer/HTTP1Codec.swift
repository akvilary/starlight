//===----------------------------------------------------------------------===//
//
//  HTTP1Codec.swift
//  StarlightServer
//
//  HTTP/1.1 request/response codec. One instance per connection,
//  reused across all keep-alive requests. In Phase 4.1a (sync path
//  only) the codec invokes handlers synchronously; Phase 4.1b will
//  make `process()` async and allow `await handler(ctx)` inline in
//  the connection Task.
//
//  Refactored from a ChannelInboundHandler to a plain class for the
//  NIOAsyncChannel architecture. The codec is driven by
//  `StarlightServer.handleHTTPConnection` which calls `process(_)`
//  for each inbound ByteBuffer chunk.
//
//===----------------------------------------------------------------------===//

import NIOCore
import NIOPosix
import StarlightCore
import StarlightHTTP
import StarlightRouting

/// HTTP/1.1 request/response codec. One instance per connection.
///
/// Owns a parser, accumulator ByteBuffer, response staging buffer,
/// and a per-request `RequestContext` — all reused across keep-alive
/// requests.
///
/// `process(_:)` takes an inbound ByteBuffer chunk and returns an
/// array of outbound ByteBuffers (responses). An empty array means
/// "not enough data yet — wait for more". A non-empty array contains
/// one or more responses (pipelined requests produce multiple).
final class HTTP1Codec: @unchecked Sendable {
    /// User handler. Set once at construction; never mutated.
    private let handler: HTTPHandler?

    /// Optional router.
    private let router: Router?

    /// Per-connection parser.
    private var parser = HTTP1Parser()

    /// Per-connection request context. Arena-backed, reset between
    /// keep-alive requests.
    private var ctx: RequestContext

    /// Byte accumulator. Bytes arrive in chunks from the socket; we
    /// stage them here until the parser signals that a full request
    /// has been consumed.
    private var accumulator: ByteBuffer = ByteBufferAllocator().buffer(capacity: 1024)

    /// Per-connection response staging buffer. We copy the handler's
    /// response bytes into this buffer before returning them — this
    /// avoids per-request retain/release on shared response storage
    /// (process-wide cached ByteBuffer) under multi-core contention.
    private var responseBuffer: ByteBuffer = ByteBufferAllocator().buffer(capacity: 512)

    /// Maximum bytes the accumulator may hold before the connection
    /// is rejected with 413. Defends against memory-exhaustion DoS.
    private let maxAccumulatorBytes: Int

    init(handler: @escaping HTTPHandler, maxAccumulatorBytes: Int = 1 * 1024 * 1024) {
        self.handler = handler
        self.router = nil
        self.maxAccumulatorBytes = maxAccumulatorBytes
        self.ctx = RequestContext()
    }

    init(router: Router, maxAccumulatorBytes: Int = 1 * 1024 * 1024) {
        self.handler = nil
        self.router = router
        self.maxAccumulatorBytes = maxAccumulatorBytes
        self.ctx = RequestContext()
    }

    /// Process an inbound ByteBuffer chunk. Returns an optional
    /// response. `nil` means "need more data".
    ///
    /// This method is `async` to support async handlers. Sync
    /// handlers are dispatched with zero overhead (direct call);
    /// async handlers are dispatched via `await` inline in the
    /// connection Task — zero Task-per-request allocation.
    func process(_ bytes: ByteBuffer) async -> HTTPResponse? {
        // Append the newly-arrived bytes to the accumulator.
        self.accumulator.writeImmutableBuffer(bytes)

        // DoS defence.
        if self.accumulator.readableBytes > self.maxAccumulatorBytes {
            self.accumulator.clear()  // discard everything
            return HTTPResponse.plaintext(
                "413 Payload Too Large\n",
                status: HTTPStatus(413, reasonPhrase: "Payload Too Large"),
                keepAlive: false
            )
        }

        var complete = false
        var consumed = 0
        var parseError: HTTP1ParseError? = nil

        self.accumulator.readWithUnsafeReadableBytes { rawBytes -> Int in
            rawBytes.withMemoryRebound(to: UInt8.self) { typedBytes in
                guard let base = typedBytes.baseAddress else {
                    complete = false
                    consumed = 0
                    return 0
                }
                let buf = UnsafeBufferPointer(start: base, count: typedBytes.count)
                do {
                    complete = try self.parser.feed(buf, into: &self.ctx)
                    consumed = self.parser.consumedBytes
                } catch let err as HTTP1ParseError {
                    parseError = err
                    consumed = 0
                } catch {
                    parseError = .unexpectedByte(offset: 0)
                    consumed = 0
                }
                return consumed
            }
        }

        if let err = parseError {
            return HTTPResponse.plaintext(
                "400 Bad Request: \(err)\n",
                status: HTTPStatus(400, reasonPhrase: "Bad Request"),
                keepAlive: false
            )
        }

        if !complete {
            return nil
        }

        // Invoke the user handler (or the router). Sync handlers
        // are called directly; async handlers via `await` inline.
        let response: HTTPResponse
        if let router = self.router {
            response = await router.handle(&self.ctx)
        } else {
            response = self.handler!(self.ctx)
        }

        // Reset per-request state for the next request on the same
        // connection (keep-alive). Arena is bulk-freed by reset().
        self.ctx.reset()
        self.parser.reset()

        return response
    }
}
