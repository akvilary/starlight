//===----------------------------------------------------------------------===//
//
//  HandlerThrowsTests.swift
//  StarlightServerTests
//
//  Verifies that a handler which throws is converted by the codec into
//  a 500 Internal Server Error response with keepAlive: false, and
//  that subsequent requests on the same connection still work.
//
//===----------------------------------------------------------------------===//

import Testing
import NIOCore
import StarlightHTTP
import StarlightRouting
@testable import StarlightServer

private struct TestError: Error, Equatable {
    let message: String
}

@Suite("Handler throws → 500")
struct HandlerThrowsTests {

    // MARK: - Sync handler

    @Test("Sync handler that throws → 500, connection closes")
    func syncHandlerThrows() async {
        let codec = HTTP1Codec(handler: { _ in throw TestError(message: "boom") })
        var bytes = ByteBufferAllocator().buffer(capacity: 64)
        bytes.writeString("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        codec.feed(bytes)

        let response = await codec.tryParse()
        #expect(response != nil)
        #expect(response!.keepAlive == false)

        // Body contains 500 marker.
        let body = response!.headerBuffer.getString(
            at: 0, length: response!.headerBuffer.readableBytes
        ) ?? ""
        #expect(body.contains("500 Internal Server Error"))
    }

    // MARK: - Async handler

    @Test("Async handler that throws → 500, connection closes")
    func asyncHandlerThrows() async {
        let builder = RouterBuilder()
        builder.get("/") { _ async throws in throw TestError(message: "async boom") }
        let codec = HTTP1Codec(router: builder.build())

        var bytes = ByteBufferAllocator().buffer(capacity: 64)
        bytes.writeString("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        codec.feed(bytes)

        let response = await codec.tryParse()
        #expect(response != nil)
        #expect(response!.keepAlive == false)

        let body = response!.headerBuffer.getString(
            at: 0, length: response!.headerBuffer.readableBytes
        ) ?? ""
        #expect(body.contains("500 Internal Server Error"))
    }

    // MARK: - Router handle propagates throws

    @Test("Router.handle rethrows handler errors")
    func routerHandleRethrows() async throws {
        let builder = RouterBuilder()
        builder.get("/fail") { _ in throw TestError(message: "router boom") }
        let router = builder.build()

        var ctx = RequestContext()
        ctx.method = .GET
        ctx.setPath("/fail")

        do {
            try await router.handle(&ctx)
            Issue.record("expected router.handle to throw")
        } catch let e as TestError {
            #expect(e.message == "router boom")
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    // MARK: - Non-throwing handlers still work

    @Test("Non-throwing sync handler is unaffected")
    func nonThrowingSyncHandler() async {
        let codec = HTTP1Codec(handler: { _ in HTTPResponse.plaintext("ok") })
        var bytes = ByteBufferAllocator().buffer(capacity: 64)
        bytes.writeString("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        codec.feed(bytes)

        let response = await codec.tryParse()
        #expect(response != nil)
        #expect(response!.keepAlive == true)
    }

    @Test("Non-throwing async handler is unaffected")
    func nonThrowingAsyncHandler() async {
        let builder = RouterBuilder()
        builder.get("/") { _ async in HTTPResponse.plaintext("ok") }
        let codec = HTTP1Codec(router: builder.build())

        var bytes = ByteBufferAllocator().buffer(capacity: 64)
        bytes.writeString("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        codec.feed(bytes)

        let response = await codec.tryParse()
        #expect(response != nil)
        #expect(response!.keepAlive == true)
    }

    // MARK: - Sync dispatch path (io_uring / epoll backend)

    @Test("tryParseSync handles throwing sync handler → 500")
    func tryParseSyncThrowingHandler() {
        let codec = HTTP1Codec(handler: { _ in throw TestError(message: "sync boom") })

        var bytes = ByteBufferAllocator().buffer(capacity: 64)
        bytes.writeString("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        codec.feed(bytes)

        let result = codec.tryParseSync()
        if case .response(let response) = result {
            #expect(response.keepAlive == false)
            let body = response.headerBuffer.getString(
                at: 0, length: response.headerBuffer.readableBytes
            ) ?? ""
            #expect(body.contains("500 Internal Server Error"))
        } else {
            Issue.record("expected .response, got \(result)")
        }
    }
}
