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
    func feed(_ bytes: ByteBuffer) {
        self.accumulator.writeImmutableBuffer(bytes)
    }

    // MARK: - Parse + dispatch (called in a loop after feed)

    /// Try to parse and dispatch one complete request from the
    /// accumulator. Returns the response, or `nil` if the
    /// accumulator doesn't have a complete request yet.
    func tryParse() async -> HTTPResponse? {
        // DoS defence.
        if self.accumulator.readableBytes > self.maxAccumulatorBytes {
            self.accumulator.clear()
            self.parser.reset()
            self.ctx.reset()
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
                return complete ? consumed : 0
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
                keepAlive: false
            )
        }

        if !complete {
            return nil
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
                keepAlive: false
            )
        }

        // Reset for next request on this connection (keep-alive).
        self.ctx.reset()
        self.parser.reset()

        return response
    }
}
