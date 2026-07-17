//===----------------------------------------------------------------------===//
//
//  HTTP1Codec.swift
//  StarlightServer
//
//  HTTP/1.1 request/response codec. One instance per connection,
//  reused across all keep-alive requests.
//
//  The codec is driven by a backend (epoll, io_uring, or NIO) in two
//  phases per TCP read event:
//    1. `feed(_:)` — append inbound bytes to the accumulator.
//    2. `tryParse()` (sync, in a loop) — parse + dispatch as many
//       complete requests as the accumulator now contains.
//       Returns one of:
//         `.response(HTTPResponse)` — sync handler completed.
//         `.needsAsync`              — handler is async; caller must
//                                      `await dispatchAsync()`.
//         `.incomplete`              — need more bytes.
//
//  Backends drive this with the same shape:
//
//      parseLoop: while true {
//          switch codec.tryParse() {
//          case .incomplete:          break parseLoop
//          case .response(let r):     write(r); if !r.keepAlive { return }
//          case .needsAsync:          let r = await codec.dispatchAsync()
//                                     write(r); if !r.keepAlive { return }
//          }
//      }
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

    /// Cached route match from `tryParse()` when the matched handler
    /// is async. Consumed by the next `dispatchAsync()` call.
    /// `nil` outside of the `.needsAsync → dispatchAsync()` window.
    private var pendingMatch: (handler: HandlerKind, params: Params)?

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

    /// Feed raw bytes directly — avoids intermediate ByteBuffer allocation.
    /// Used by the io_uring/epoll backends which read into a raw buffer.
    func feed(_ bytes: UnsafeBufferPointer<UInt8>) {
        let projected = self.accumulator.readableBytes + bytes.count
        if projected > self.maxAccumulatorBytes {
            self.overflowed = true
            return
        }
        self.accumulator.writeBytes(bytes)
    }

    // MARK: - Parse + dispatch (the single hot-path entry point)

    /// Result of a synchronous parse + dispatch attempt.
    enum ParseResult {
        /// Sync handler completed — the response is ready to write.
        case response(HTTPResponse)
        /// Handler is async — caller must `await codec.dispatchAsync()`
        /// to obtain the response.
        case needsAsync
        /// Accumulator doesn't yet contain a complete request — caller
        /// must `feed(_:)` more bytes.
        case incomplete
    }

    /// Parse + dispatch **synchronously**. The single hot-path entry
    /// point shared by all backends (epoll, io_uring, NIO).
    ///
    /// For sync handlers: parses, dispatches, resets, returns `.response`.
    /// For async handlers: parses, caches the route match in
    /// `pendingMatch`, returns `.needsAsync` — the caller must then
    /// call `await dispatchAsync()` to actually run the handler.
    /// If the accumulator doesn't yet hold a complete request,
    /// returns `.incomplete` (caller should `feed(_:)` more bytes).
    ///
    /// All error paths (400 malformed, 413 too large, 404 not found,
    /// 500 handler throw / misconfiguration) are centralised here and
    /// in `dispatchAsync()` so backends cannot drift apart in how
    /// they synthesise these responses.
    func tryParse() -> ParseResult {
        switch self.parseAndExtract() {
        case .incomplete:
            return .incomplete
        case .errorResponse(let r):
            return .response(r)
        case .parsed:
            break
        }

        // Dispatch the parsed request through the registered handler
        // or router. The router path performs its own match + 404;
        // the handler path skips routing.
        if let router = self.router {
            guard let m = router.match(method: self.ctx.method, path: self.ctx.path) else {
                let r = self.notFoundResponse()
                self.afterDispatch()
                return .response(r)
            }
            self.ctx.params = m.params
            switch m.handler {
            case .sync(let fn):
                let r: HTTPResponse
                do {
                    r = try fn(self.ctx)
                } catch {
                    self.afterDispatch()
                    return .response(self.synthesize500(error))
                }
                self.afterDispatch()
                return .response(r)
            case .async:
                // Cache the match so dispatchAsync() doesn't re-match.
                self.pendingMatch = (m.handler, m.params)
                return .needsAsync
            }
        } else if let handler = self.handler {
            let r: HTTPResponse
            do {
                r = try handler(self.ctx)
            } catch {
                self.afterDispatch()
                return .response(self.synthesize500(error))
            }
            self.afterDispatch()
            return .response(r)
        } else {
            // Neither router nor handler configured — construction-
            // time bug. StarlightServer.start() pre-validates this,
            // but we synthesise a 500 defensively rather than crash.
            let r = self.internalErrorResponse()
            self.afterDispatch()
            return .response(r)
        }
    }

    /// Async continuation — used when `tryParse()` returned `.needsAsync`.
    /// Must be called from an async context, exactly once per
    /// `.needsAsync` result.
    ///
    /// Consumes the cached route match from `pendingMatch` and invokes
    /// the async handler. The cache avoids a second `router.match()`
    /// call (which would otherwise run twice — once to discover the
    /// handler is async, once to dispatch).
    func dispatchAsync() async -> HTTPResponse {
        precondition(self.pendingMatch != nil,
            "dispatchAsync() called without a preceding .needsAsync from tryParse()")
        let cached = self.pendingMatch!
        self.pendingMatch = nil
        self.ctx.params = cached.params

        let response: HTTPResponse
        do {
            switch cached.handler {
            case .sync(let fn):
                // The handler was tagged async at compose time (e.g.
                // async-only middleware promoted a sync handler).
                response = try fn(self.ctx)
            case .async(let fn):
                response = try await fn(self.ctx)
            }
        } catch {
            self.afterDispatch()
            return self.synthesize500(error)
        }
        self.afterDispatch()
        return response
    }

    // MARK: - Shared helpers

    /// Reset state after dispatch (called by both sync and async paths).
    internal func afterDispatch() {
        self.ctx.reset()
        self.parser.reset()
        // Compact the accumulator: move unread bytes (pipelined
        // requests) to the front and reclaim consumed-byte space.
        // Safe to do here because ctx.reset() already released all
        // COW slices (path, body) — the accumulator is uniquely
        // referenced, so discardReadBytes() compacts in-place with
        // zero allocation. For the common case (all bytes consumed,
        // no pipelining) this is a no-op.
        self.accumulator.discardReadBytes()
    }

    /// `404 Not Found` response for unmatched routes. Uses the
    /// per-connection `ctx.responseBuffer` for zero-alloc error
    /// responses on keep-alive connections.
    internal func notFoundResponse() -> HTTPResponse {
        return HTTPResponse.plaintext(
            "404 Not Found: \(self.ctx.method) \(self.ctx.pathString)\n",
            status: HTTPStatus(404, reasonPhrase: "Not Found"),
            keepAlive: false,
            into: &self.ctx.responseBuffer
        )
    }

    /// `500 Internal Server Error` response for misconfiguration
    /// (no router/handler wired up) — defensively returned rather
    /// than crashing when StarlightServer's precondition is bypassed.
    internal func internalErrorResponse() -> HTTPResponse {
        return HTTPResponse.plaintext(
            "500 Internal Server Error\n",
            status: HTTPStatus(500, reasonPhrase: "Internal Server Error"),
            keepAlive: false,
            into: &self.responseBuffer
        )
    }

    /// `500 Internal Server Error` response for an uncaught handler
    /// error. The connection is closed after the response is written
    /// (`keepAlive: false`) — a thrown error may indicate corrupted
    /// state, so we don't trust the connection to recover.
    ///
    /// The error itself is intentionally not logged at this layer:
    /// `stderr` is global mutable state under Swift 6 strict
    /// concurrency, and a logging strategy belongs in user-supplied
    /// error-handling middleware (a future addition) rather than in
    /// the codec. Production builds silently convert the throw to
    /// 500; tests can verify the 500 status code.
    internal func synthesize500(_ error: Error) -> HTTPResponse {
        return self.internalErrorResponse()
    }

    // MARK: - Internal: parsing phase

    /// Internal result of the parsing phase.
    private enum ParseState {
        case incomplete
        case errorResponse(HTTPResponse)  // 400, 413
        case parsed                        // ready for dispatch
    }

    /// Parse one request from the accumulator. Extracts zero-copy
    /// path/body slices and advances the reader index. On error or
    /// incomplete input, resets state appropriately.
    private func parseAndExtract() -> ParseState {
        // DoS defence — flag was set by feed() when the incoming
        // chunk would have exceeded maxAccumulatorBytes.
        if self.overflowed {
            self.overflowed = false
            self.accumulator.clear()
            self.parser.reset()
            self.ctx.reset()
            return .errorResponse(HTTPResponse.plaintext(
                "413 Payload Too Large\n",
                status: HTTPStatus(413, reasonPhrase: "Payload Too Large"),
                keepAlive: false,
                into: &self.responseBuffer
            ))
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
            self.accumulator.clear()
            self.parser.reset()
            self.ctx.reset()
            return .errorResponse(HTTPResponse.plaintext(
                "400 Bad Request: \(err)\n",
                status: HTTPStatus(400, reasonPhrase: "Bad Request"),
                keepAlive: false,
                into: &self.responseBuffer
            ))
        }

        if !complete {
            return .incomplete
        }

        // Extract path as a zero-copy COW ByteBuffer slice.
        if self.parser.pathLength > 0 {
            self.ctx.path = self.accumulator.getSlice(
                at: readerIndexBefore + self.parser.pathStart,
                length: self.parser.pathLength
            ) ?? self.ctx.path
        }

        // Note: query string is copied into `ctx.query` directly by
        // the parser inside `feed()` — same encapsulation pattern as
        // headers (`ctx.headers.copyBlock`). The codec performs no
        // query copy itself.

        // Extract body as a zero-copy COW ByteBuffer slice.
        let bodyLen = self.parser.bodyLength
        if bodyLen > 0 {
            self.ctx.body = self.accumulator.getSlice(
                at: readerIndexBefore + self.parser.bodyStart,
                length: bodyLen
            )
        }

        // Discard consumed bytes from the accumulator.
        self.accumulator.moveReaderIndex(forwardBy: consumed)

        return .parsed
    }
}
