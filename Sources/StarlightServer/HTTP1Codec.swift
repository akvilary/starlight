//===----------------------------------------------------------------------===//
//
//  HTTP1Codec.swift
//  StarlightServer
//
//  HTTP/1.1 request/response codec. One instance per connection,
//  reused across all keep-alive requests.
//
//  The codec is driven by `StarlightServer.handleHTTPConnection`:
//    1. `feed(_:)` — called once per inbound ByteBuffer chunk
//    2. `tryParse()` — called in a loop to parse and dispatch as
//       many complete requests as the accumulator now contains
//       (handles pipelining)
//
//===----------------------------------------------------------------------===//

import NIOCore
import NIOPosix
import StarlightCore
import StarlightHTTP
import StarlightRouting

/// HTTP/1.1 request/response codec. One instance per connection.
final class HTTP1Codec: @unchecked Sendable {
    private let handler: HTTPHandler?
    private let router: Router?
    private var parser = HTTP1Parser()
    private var ctx: RequestContext
    private var accumulator: ByteBuffer = ByteBufferAllocator().buffer(capacity: 1024)
    private let maxAccumulatorBytes: Int

    /// Reusable response buffer — cleared and refilled per request.
    /// `ByteBuffer` is COW, so `HTTPResponse(headerBuffer: responseBuffer)`
    /// shares storage until the next write triggers copy-on-write.
    /// Eliminates per-error-response ByteBuffer allocation.
    private var responseBuffer: ByteBuffer = ByteBufferAllocator().buffer(capacity: 512)

    /// Set when feed() detects that writing the incoming chunk would
    /// exceed `maxAccumulatorBytes`. The next `tryParse()` call
    /// consumes this flag and returns a 413 response.
    private var overflowed: Bool = false

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

    // MARK: - Feed (called once per inbound chunk)

    /// Append new inbound bytes to the accumulator. Called once per
    /// TCP read event — bytes are NOT re-added on subsequent
    /// `tryParse()` calls.
    ///
    /// - Important: The size limit is enforced **here**, before the
    ///   bytes are written, to prevent a single large TCP chunk from
    ///   growing the accumulator to gigabytes. If the projected size
    ///   exceeds `maxAccumulatorBytes`, the chunk is dropped and the
    ///   `overflowed` flag is set so the next `tryParse()` returns 413.
    func feed(_ bytes: ByteBuffer) {
        let projected = self.accumulator.readableBytes + bytes.readableBytes
        if projected > self.maxAccumulatorBytes {
            self.overflowed = true
            return
        }
        self.accumulator.writeImmutableBuffer(bytes)
    }

    // MARK: - Parse + dispatch (called in a loop after feed)

    /// Try to parse and dispatch one complete request from the
    /// accumulator. Returns the response, or `nil` if the
    /// accumulator doesn't have a complete request yet.
    func tryParse() async -> HTTPResponse? {
        // DoS defence — flag was set by feed() when the incoming
        // chunk would have exceeded maxAccumulatorBytes.
        if self.overflowed {
            self.overflowed = false
            self.accumulator.clear()
            self.parser.reset()
            self.ctx.reset()
            return HTTPResponse.plaintext(
                "413 Payload Too Large\n",
                status: HTTPStatus(413, reasonPhrase: "Payload Too Large"),
                keepAlive: false,
                into: &self.responseBuffer
            )
        }

        var complete = false
        var consumed = 0
        var parseError: HTTP1ParseError? = nil
        let readerIndexBefore = self.accumulator.readerIndex

        self.accumulator.withUnsafeReadableBytes { rawBytes in
            rawBytes.withMemoryRebound(to: UInt8.self) { typedBytes in
                guard let base = typedBytes.baseAddress else {
                    complete = false
                    consumed = 0
                    return
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
            }
        }

        if let err = parseError {
            // CRITICAL: reset all state to prevent an infinite loop.
            // Without this the parser stays in .error (or an
            // inconsistent state), consumedBytes doesn't advance,
            // and the while-loop in handleHTTPConnection spins
            // forever generating 400 responses on the same bytes.
            self.accumulator.clear()
            self.parser.reset()
            self.ctx.reset()
            return HTTPResponse.plaintext(
                "400 Bad Request: \(err)\n",
                status: HTTPStatus(400, reasonPhrase: "Bad Request"),
                keepAlive: false,
                into: &self.responseBuffer
            )
        }

        if !complete {
            return nil
        }

        // Extract path as a zero-copy COW ByteBuffer slice (same
        // technique as body). Avoids the heap String allocation that
        // String(decoding:as:) incurs for paths > 15 bytes.
        if self.parser.pathLength > 0 {
            self.ctx.path = self.accumulator.getSlice(
                at: readerIndexBefore + self.parser.pathStart,
                length: self.parser.pathLength
            ) ?? self.ctx.path
        }

        // Extract body as a zero-copy COW ByteBuffer slice from the
        // accumulator. The body bytes live at
        // [readerIndexBefore + bodyStart, readerIndexBefore + consumed)
        // in the buffer's underlying storage. `getSlice` bumps the
        // storage's reference count — no memcpy, no arena allocation.
        // When `feed()` later writes new bytes and the accumulator
        // grows, COW gives the accumulator fresh storage while this
        // slice retains the old one.
        let bodyLen = self.parser.bodyLength
        if bodyLen > 0 {
            self.ctx.body = self.accumulator.getSlice(
                at: readerIndexBefore + self.parser.bodyStart,
                length: bodyLen
            )
        }

        // Discard consumed bytes from the accumulator. Deferred from
        // parse because NIO's getSlice requires index >= readerIndex
        // — we must extract all zero-copy slices BEFORE advancing.
        // After this call, only unconsumed (pipelined) bytes remain.
        self.accumulator.moveReaderIndex(forwardBy: consumed)

        // Invoke the user handler (or the router).
        let response: HTTPResponse
        if let router = self.router {
            response = await router.handle(&self.ctx)
        } else if let handler = self.handler {
            response = handler(self.ctx)
        } else {
            response = HTTPResponse.plaintext(
                "500 Internal Server Error\n",
                status: HTTPStatus(500, reasonPhrase: "Internal Server Error"),
                keepAlive: false,
                into: &self.responseBuffer
            )
        }

        // Reset for next request on this connection (keep-alive).
        self.ctx.reset()
        self.parser.reset()

        return response
    }
}
