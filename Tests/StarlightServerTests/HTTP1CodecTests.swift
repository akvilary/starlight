//===----------------------------------------------------------------------===//
//
//  HTTP1CodecTests.swift
//  StarlightServerTests
//
//  Regression tests for HTTP1Codec — specifically targeting the infinite
//  400-response loop that occurred when parse errors did not reset
//  parser/ctx/accumulator state.
//
//===----------------------------------------------------------------------===//

import Testing
import NIOCore
import StarlightHTTP
import StarlightCore
import StarlightRouting
@testable import StarlightServer

@Suite("HTTP1Codec")
struct HTTP1CodecTests {

    // MARK: - Infinite-loop regression (the headline bug)

    @Test("Malformed request produces exactly one 400, then nil — no infinite loop")
    func malformedRequestSingle400() async {
        let codec = HTTP1Codec(handler: { _ in HTTPResponse.plaintext("ok") })
        var bytes = ByteBufferAllocator().buffer(capacity: 64)
        bytes.writeString("GARBAGE WITHOUT SPACES OR VERSION\r\n\r\n")
        codec.feed(bytes)

        // First call: should return one 400 response.
        let response1 = await codec.tryParse()
        #expect(response1 != nil)
        #expect(response1!.keepAlive == false)

        // Second call: accumulator was cleared → must return nil.
        // Before the fix this returned another 400, then another,
        // forever — the "idle loop".
        let response2 = await codec.tryParse()
        #expect(response2 == nil)
    }

    @Test("Unsupported HTTP version produces one 400, then nil")
    func unsupportedVersionSingle400() async {
        let codec = HTTP1Codec(handler: { _ in HTTPResponse.plaintext("ok") })
        var bytes = ByteBufferAllocator().buffer(capacity: 64)
        bytes.writeString("GET / HTTP/2.0\r\n\r\n")
        codec.feed(bytes)

        let response1 = await codec.tryParse()
        #expect(response1 != nil)
        #expect(response1!.keepAlive == false)

        let response2 = await codec.tryParse()
        #expect(response2 == nil)
    }

    @Test("Malformed header produces one 400, then nil")
    func malformedHeaderSingle400() async {
        let codec = HTTP1Codec(handler: { _ in HTTPResponse.plaintext("ok") })
        var bytes = ByteBufferAllocator().buffer(capacity: 128)
        bytes.writeString("GET / HTTP/1.1\r\nNoColonHereJustText\r\n\r\n")
        codec.feed(bytes)

        let response1 = await codec.tryParse()
        #expect(response1 != nil)
        #expect(response1!.keepAlive == false)

        let response2 = await codec.tryParse()
        #expect(response2 == nil)
    }

    // MARK: - 413 DoS defence

    @Test("Accumulator overflow produces one 413, then nil")
    func overflowSingle413() async {
        let codec = HTTP1Codec(
            handler: { _ in HTTPResponse.plaintext("ok") },
            maxAccumulatorBytes: 16
        )
        var bytes = ByteBufferAllocator().buffer(capacity: 128)
        bytes.writeBytes([UInt8](repeating: 0x41, count: 100))
        codec.feed(bytes)

        let response1 = await codec.tryParse()
        #expect(response1 != nil)
        #expect(response1!.keepAlive == false)

        // Accumulator was cleared, parser was reset → nil.
        let response2 = await codec.tryParse()
        #expect(response2 == nil)
    }

    @Test("Overflow detected in feed() — bytes are NOT written to accumulator")
    func overflowInFeedNotTryParse() async {
        let codec = HTTP1Codec(
            handler: { _ in HTTPResponse.plaintext("ok") },
            maxAccumulatorBytes: 32
        )
        // Feed a valid small request first.
        var small = ByteBufferAllocator().buffer(capacity: 64)
        small.writeString("GET / HTTP/1.1\r\n\r\n")
        codec.feed(small)
        // This should parse fine.
        let ok = await codec.tryParse()
        #expect(ok != nil)
        #expect(ok!.keepAlive == true)

        // Now feed a chunk that exceeds the limit. The bytes should
        // be dropped immediately in feed(), not buffered.
        var huge = ByteBufferAllocator().buffer(capacity: 128)
        huge.writeBytes([UInt8](repeating: 0x41, count: 100))
        codec.feed(huge)

        let resp = await codec.tryParse()
        #expect(resp != nil)
        #expect(resp!.keepAlive == false)

        // Recovery: feed a valid request after overflow.
        var good = ByteBufferAllocator().buffer(capacity: 64)
        good.writeString("GET /ok HTTP/1.1\r\n\r\n")
        codec.feed(good)
        let recovered = await codec.tryParse()
        #expect(recovered != nil)
        #expect(recovered!.keepAlive == true)
    }

    // MARK: - Valid-after-error recovery

    @Test("Valid request parses correctly after a prior error on the same codec")
    func validAfterError() async {
        let codec = HTTP1Codec(handler: { _ in HTTPResponse.plaintext("ok") })

        // Feed malformed bytes.
        var bad = ByteBufferAllocator().buffer(capacity: 64)
        bad.writeString("GARBAGE\r\n\r\n")
        codec.feed(bad)
        let errResponse = await codec.tryParse()
        #expect(errResponse != nil)
        #expect(errResponse!.keepAlive == false)

        // Now feed a valid request on the same codec (simulates the
        // client reusing the connection — or more realistically, the
        // next TCP packet after a partial-read scenario).
        var good = ByteBufferAllocator().buffer(capacity: 128)
        good.writeString("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
        codec.feed(good)
        let okResponse = await codec.tryParse()
        #expect(okResponse != nil)
        #expect(okResponse!.keepAlive == true)
    }

    // MARK: - Pipelining still works

    @Test("Two pipelined requests produce exactly two responses, then nil")
    func pipeliningTwoRequests() async {
        let codec = HTTP1Codec(handler: { _ in HTTPResponse.plaintext("ok") })
        var bytes = ByteBufferAllocator().buffer(capacity: 256)
        bytes.writeString("GET /first HTTP/1.1\r\n\r\nGET /second HTTP/1.1\r\n\r\n")
        codec.feed(bytes)

        let r1 = await codec.tryParse()
        #expect(r1 != nil)

        let r2 = await codec.tryParse()
        #expect(r2 != nil)

        let r3 = await codec.tryParse()
        #expect(r3 == nil)
    }

    // MARK: - Normal request dispatches handler

    @Test("Valid GET request dispatches handler and returns its response")
    func validGetDispatches() async {
        let codec = HTTP1Codec(handler: { ctx in
            #expect(ctx.method == .GET)
            return HTTPResponse.plaintext("hello")
        })
        var bytes = ByteBufferAllocator().buffer(capacity: 128)
        bytes.writeString("GET /hello HTTP/1.1\r\nHost: x\r\n\r\n")
        codec.feed(bytes)

        let response = await codec.tryParse()
        #expect(response != nil)
        #expect(response!.keepAlive == true)
    }

    // MARK: - Router dispatch through codec

    @Test("Router dispatches through codec and populates params")
    func routerDispatchThroughCodec() async {
        let router = Router()
        router.get("/users/:id") { ctx in
            let id = ctx.params["id"] ?? "?"
            return HTTPResponse.plaintext("user \(id)")
        }
        let codec = HTTP1Codec(router: router)
        var bytes = ByteBufferAllocator().buffer(capacity: 128)
        bytes.writeString("GET /users/42 HTTP/1.1\r\nHost: x\r\n\r\n")
        codec.feed(bytes)

        let response = await codec.tryParse()
        #expect(response != nil)
        #expect(response!.keepAlive == true)

        // Verify the response body contains "user 42".
        let body = response!.headerBuffer.getString(at: 0, length: response!.headerBuffer.readableBytes)
        #expect(body?.contains("user 42") == true)
    }
}
