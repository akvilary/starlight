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

    /// Cached route match from `tryParseSync()`, used by
    /// `dispatchAsync()` to avoid matching the route twice.
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
    /// Used by the io_uring backend which reads into a raw buffer.
    func feed(_ bytes: UnsafeBufferPointer<UInt8>) {
        let projected = self.accumulator.readableBytes + bytes.count
        if projected > self.maxAccumulatorBytes {
            self.overflowed = true
            return
        }
        self.accumulator.writeBytes(bytes)
    }

    // MARK: - Parse + dispatch (called in a loop after feed)

    /// Result of a synchronous parse + dispatch attempt.
    enum SyncParseResult {
        case response(HTTPResponse)  // sync response ready
        case incomplete              // need more data
        case needsAsync              // handler is async — caller must await
    }

    /// Parse + dispatch **synchronously**. No async overhead — no
    /// continuation, no Task allocation. Used by the io_uring backend.
    ///
    /// For sync handlers: parses, dispatches, resets, returns the response.
    /// For async handlers: parses, returns `.needsAsync` — caller must
    /// then call `dispatchAsync()`.
    func tryParseSync() -> SyncParseResult {
        switch self.parseAndExtract() {
        case .incomplete:
            return .incomplete
        case .errorResponse(let r):
            return .response(r)
        case .parsed:
            break
        }

        // Sync dispatch
        if let router = self.router {
            router.freeze()
            guard let m = router.match(method: self.ctx.method, path: self.ctx.path) else {
                let r = HTTPResponse.plaintext(
                    "404 Not Found: \(self.ctx.method) \(self.ctx.pathString)\n",
                    status: HTTPStatus(404, reasonPhrase: "Not Found"),
                    keepAlive: false,
                    into: &self.ctx.responseBuffer
                )
                self.afterDispatch()
                return .response(r)
            }
            self.ctx.params = m.params
            switch m.handler {
            case .sync(let fn):
                let r = fn(self.ctx)
                self.afterDispatch()
                return .response(r)
            case .async(let fn):
                // Cache the match so dispatchAsync() doesn't re-match.
                self.pendingMatch = (m.handler, m.params)
                return .needsAsync
            }
        } else if let handler = self.handler {
            let r = handler(self.ctx)
            self.afterDispatch()
            return .response(r)
        } else {
            let r = HTTPResponse.plaintext(
                "500 Internal Server Error\n",
                status: HTTPStatus(500, reasonPhrase: "Internal Server Error"),
                keepAlive: false,
                into: &self.responseBuffer
            )
            self.afterDispatch()
            return .response(r)
        }
    }

    /// Async dispatch — used when `tryParseSync()` returned `.needsAsync`.
    /// Must be called from an async context.
    ///
    /// Uses the cached route match from `tryParseSync()` to avoid
    /// matching the route a second time.
    func dispatchAsync() async -> HTTPResponse {
        let response: HTTPResponse

        if let cached = self.pendingMatch {
            // Use cached match — avoids redundant router.match() call.
            self.pendingMatch = nil
            self.ctx.params = cached.params
            switch cached.handler {
            case .sync(let fn):
                response = fn(self.ctx)
            case .async(let fn):
                response = await fn(self.ctx)
            }
        } else if let router = self.router {
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
        self.afterDispatch()
        return response
    }

    /// Reset state after dispatch (called by both sync and async paths).
    internal func afterDispatch() {
        self.ctx.reset()
        self.parser.reset()
    }

    /// Try to parse and dispatch one complete request from the
    /// accumulator. Returns the response, or `nil` if the
    /// accumulator doesn't have a complete request yet.
    func tryParse() async -> HTTPResponse? {
        switch self.parseAndExtract() {
        case .incomplete:
            return nil
        case .errorResponse(let r):
            return r
        case .parsed:
            break
        }

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

        self.afterDispatch()
        return response
    }

    // MARK: - Internal: shared parsing logic

    /// Internal result of the parsing phase.
    private enum ParseState {
        case incomplete
        case errorResponse(HTTPResponse)  // 400, 413
        case parsed                        // ready for dispatch
    }

    /// Parse one request from the accumulator. Extracts zero-copy
    /// path/body slices and advances the reader index. On error or
    /// incomplete input, resets state appropriately.
    ///
    /// Shared between `tryParse()` (async) and `tryParseSync()`.
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
