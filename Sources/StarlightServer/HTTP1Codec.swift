//===----------------------------------------------------------------------===//
//
//  HTTP1Codec.swift
//  StarlightServer
//
//  ChannelHandler that turns a TCP byte stream into HTTP/1.1 request /
//  response cycles. Sits inside the per-connection pipeline after
//  accept. For each inbound `ByteBuffer` it:
//
//    1. Appends the bytes to an accumulator `ByteBuffer`.
//    2. Feeds the accumulator's readable slice to the `HTTP1Parser`.
//    3. When a complete request has been parsed, calls the user
//       handler and writes the response back.
//    4. Discards the consumed bytes from the accumulator and resets
//       the parser for the next (pipelined) request.
//
//  Pipeline shape (Phase 2):
//
//    socket → TCP echo  |  HTTP1Codec → user handler
//                       |
//                       └─ toggle via StarlightServer's `mode` parameter
//
//  Why this lives in `StarlightServer` (not `StarlightHTTP`): a
//  `ChannelHandler` is intrinsically tied to NIO's `ChannelPipeline`
//  API, which is server-runtime machinery. `StarlightHTTP` stays free
//  of NIO types so it can be reused for parsing HTTP in other
//  contexts (proxies, test harnesses, parsers fed from disk).
//
//===----------------------------------------------------------------------===//

import Foundation
import NIOCore
import NIOPosix
import StarlightCore
import StarlightHTTP
import StarlightRouting

/// Closure that, given a parsed request context, produces an HTTP
/// response. The handler runs **synchronously on the connection's
/// event loop** — exactly the H2O / Actix pattern. Async handlers
/// will be wired in Phase 4 once the middleware protocol is in place.
///
/// Deprecated alias — `HTTPHandler` now lives in `StarlightHTTP`
/// alongside `HTTPResponse`. Kept here for source compatibility with
/// Phase 2 callers that imported it from `StarlightServer`.
public typealias _HTTPHandler_Deprecated = HTTPHandler

/// ChannelHandler that decodes HTTP/1.1 requests and encodes HTTP/1.1
/// responses.
///
/// Each connection owns one `HTTP1Codec` instance, which in turn owns
/// a parser and a per-request context. The context is reset between
/// requests (bulk-free arena) so a long-lived keep-alive connection
/// allocates nothing per request after the first.
final class HTTP1Codec: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    /// User handler. Set once at construction; never mutated.
    ///
    /// Either `handler` or `router` is set, never both. When `router`
    /// is non-nil it takes precedence — the codec invokes
    /// `router.handle(&ctx)`, which performs routing + middleware and
    /// dispatches to the matched route's handler.
    private let handler: HTTPHandler?

    /// Optional router. When set, replaces `handler` as the dispatch
    /// entry point for each request.
    private let router: Router?

    /// Per-connection parser. Reset between keep-alive requests.
    private var parser = HTTP1Parser()

    /// Per-connection request context. Arena-backed, reset between
    /// keep-alive requests.
    private var ctx: RequestContext

    /// Byte accumulator. Bytes arrive in chunks from the socket; we
    /// stage them here until the parser signals that a full request
    /// has been consumed.
    private var accumulator: ByteBuffer = ByteBufferAllocator().buffer(capacity: 1024)

    /// Per-connection response staging buffer. We copy the handler's
    /// response bytes into this buffer before handing them to
    /// `context.write`. This avoids the per-request retain/release on
    /// any *shared* response storage (e.g. a process-wide cached
    /// "Hello, World!" ByteBuffer) — under multi-core contention those
    /// atomic refcount operations dominate throughput, so paying a
    /// ~100-byte `memcpy` per request is a significant net win.
    ///
    /// The buffer is reused across requests on the same connection:
    /// we `clear()` it before each write, which resets the reader /
    /// writer indices without freeing the underlying storage.
    private var responseBuffer: ByteBuffer = ByteBufferAllocator().buffer(capacity: 512)

    init(handler: @escaping HTTPHandler) {
        self.handler = handler
        self.router = nil
        self.ctx = RequestContext()
    }

    init(router: Router) {
        self.handler = nil
        self.router = router
        self.ctx = RequestContext()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // Append the newly-arrived bytes to the accumulator.
        var input = self.unwrapInboundIn(data)
        self.accumulator.writeBuffer(&input)

        // Try to parse as many requests as the buffer contains
        // (pipelining).
        parseLoop: while true {
            // Read the accumulator's readable slice with an unsafe
            // pointer so we can hand it to the parser without copying.
            // `readWithUnsafeReadableBytes` returns the number of bytes
            // to discard from the head of the readable slice; we return
            // `parsed.consumed` so the buffer shrinks in lock-step with
            // the parser.
            var complete = false
            var consumed = 0
            var parseError: HTTP1ParseError? = nil

            self.accumulator.readWithUnsafeReadableBytes { bytes -> Int in
                let discarded: Int = bytes.withMemoryRebound(to: UInt8.self) { typedBytes in
                    let buf = UnsafeBufferPointer(start: typedBytes.baseAddress!, count: typedBytes.count)
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
                return discarded
            }

            // Discard whatever the parser has consumed from the start
            // of the accumulator. (Already done by readWithUnsafeReadableBytes
            // returning `consumed`, but kept here for clarity — the
            // return value of `readWithUnsafeReadableBytes` moves the
            // reader index forward.)

            if let err = parseError {
                // 400 Bad Request — close connection after writing.
                let response = HTTPResponse.plaintext(
                    "400 Bad Request: \(err)\n",
                    allocator: context.channel.allocator,
                    keepAlive: false
                )
                context.write(self.wrapOutboundOut(response.buffer), promise: nil)
                context.flush()
                context.close(promise: nil)
                return
            }

            if !complete {
                // Not enough bytes yet — wait for the next channelRead.
                return
            }

            // A complete request has been parsed. Invoke the user handler
            // (or the router, which dispatches via routing + middleware)
            // synchronously on this event loop thread.
            let response: HTTPResponse
            if let router = self.router {
                response = router.handle(&self.ctx)
            } else {
                response = self.handler!(self.ctx)
            }

            // Stage the response bytes into the per-connection buffer.
            // This is the key optimization that removes cross-core ARC
            // traffic on shared response storage: instead of handing
            // the handler's ByteBuffer (which may have shared COW
            // storage with a process-wide cache) directly to
            // `context.write`, we copy its readable bytes into this
            // connection's private buffer and write that.
            //
            // The copy is ~100 bytes of `memcpy` for a typical
            // response; the ARC savings on a 12-core machine are
            // 4-8 atomic ops per request that would otherwise
            // bounce a cache line between cores.
            self.responseBuffer.clear()
            self.responseBuffer.writeBytes(response.buffer.readableBytesView)

            // Reset per-request state for the next request on the same
            // connection (keep-alive). Arena is bulk-freed by reset().
            self.ctx.reset()
            self.parser.reset()

            // Write & flush. The connection's owning event loop is the
            // thread we're on, so this is non-blocking from the caller's
            // perspective.
            context.write(self.wrapOutboundOut(self.responseBuffer), promise: nil)
            context.flush()

            // Loop back and see if more pipelined requests are buffered.
            // If the accumulator is empty now, the next `feed` call will
            // hit `consumedBytes < count == false` and return immediately.
            if self.accumulator.readableBytes == 0 {
                break parseLoop
            }
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // Pipeline-level error (e.g. socket reset). Close the channel.
        context.close(promise: nil)
    }
}
