//===----------------------------------------------------------------------===//
//
//  HTTPErrorTests.swift
//  StarlightServerTests
//
//  Verifies that throwing HTTPError from a handler produces a response
//  with the correct status code and body, instead of the generic 500.
//
//===----------------------------------------------------------------------===//

import Testing
import NIOCore
import StarlightHTTP
import StarlightRouting
@testable import StarlightServer

@Suite("HTTPError")
struct HTTPErrorTests {

    // MARK: - HTTPError enum itself

    @Test("Each error maps to the correct status code")
    func statusMapping() {
        #expect(HTTPError.badRequest.status.code == 400)
        #expect(HTTPError.unauthorized.status.code == 401)
        #expect(HTTPError.forbidden.status.code == 403)
        #expect(HTTPError.notFound.status.code == 404)
        #expect(HTTPError.methodNotAllowed.status.code == 405)
        #expect(HTTPError.conflict.status.code == 409)
        #expect(HTTPError.payloadTooLarge.status.code == 413)
        #expect(HTTPError.tooManyRequests.status.code == 429)
        #expect(HTTPError.internalError.status.code == 500)
        #expect(HTTPError.notImplemented.status.code == 501)
        #expect(HTTPError.badGateway.status.code == 502)
        #expect(HTTPError.serviceUnavailable.status.code == 503)
        #expect(HTTPError.gatewayTimeout.status.code == 504)
    }

    @Test("Each error has a non-empty default message")
    func defaultMessageIsNonEmpty() {
        for error in [
            HTTPError.badRequest, .unauthorized, .forbidden, .notFound,
            .methodNotAllowed, .conflict, .payloadTooLarge, .tooManyRequests,
            .internalError, .notImplemented, .badGateway, .serviceUnavailable,
            .gatewayTimeout,
        ] {
            #expect(!error.defaultMessage.isEmpty,
                "HTTPError.\(error) has empty defaultMessage")
            #expect(error.defaultMessage.contains(String(error.status.code)),
                "HTTPError.\(error) defaultMessage should contain status code")
        }
    }

    // MARK: - Throwing HTTPError from sync handler

    @Test("Sync handler throws .notFound → 404 response")
    func syncThrowsNotFound() async {
        var codec = HTTP1Codec(handler: { _ in throw HTTPError.notFound })
        var bytes = ByteBufferAllocator().buffer(capacity: 64)
        bytes.writeString("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        codec.feed(bytes)

        let response = await codec.parseAndDispatch()
        #expect(response != nil)
        #expect(response!.keepAlive == false)

        let body = response!.headerBuffer.getString(
            at: 0, length: response!.headerBuffer.readableBytes
        ) ?? ""
        #expect(body.contains("404 Not Found"))
    }

    @Test("Sync handler throws .forbidden → 403 response")
    func syncThrowsForbidden() async {
        var codec = HTTP1Codec(handler: { _ in throw HTTPError.forbidden })
        var bytes = ByteBufferAllocator().buffer(capacity: 64)
        bytes.writeString("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        codec.feed(bytes)

        let response = await codec.parseAndDispatch()
        #expect(response != nil)

        let body = response!.headerBuffer.getString(
            at: 0, length: response!.headerBuffer.readableBytes
        ) ?? ""
        #expect(body.contains("403 Forbidden"))
    }

    // MARK: - Throwing HTTPError from async handler

    @Test("Async handler throws .unauthorized → 401 response")
    func asyncThrowsUnauthorized() async {
        let builder = RouterBuilder()
        builder.get("/") { _ async throws in throw HTTPError.unauthorized }
        var codec = HTTP1Codec(router: builder.build())

        var bytes = ByteBufferAllocator().buffer(capacity: 64)
        bytes.writeString("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        codec.feed(bytes)

        let response = await codec.parseAndDispatch()
        #expect(response != nil)

        let body = response!.headerBuffer.getString(
            at: 0, length: response!.headerBuffer.readableBytes
        ) ?? ""
        #expect(body.contains("401 Unauthorized"))
    }

    @Test("Async handler throws .conflict → 409 response")
    func asyncThrowsConflict() async {
        let builder = RouterBuilder()
        builder.get("/") { _ async throws in throw HTTPError.conflict }
        var codec = HTTP1Codec(router: builder.build())

        var bytes = ByteBufferAllocator().buffer(capacity: 64)
        bytes.writeString("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        codec.feed(bytes)

        let response = await codec.parseAndDispatch()
        #expect(response != nil)

        let body = response!.headerBuffer.getString(
            at: 0, length: response!.headerBuffer.readableBytes
        ) ?? ""
        #expect(body.contains("409 Conflict"))
    }

    // MARK: - Non-HTTP errors still produce 500

    @Test("Non-HTTPError throw still produces 500")
    func nonHTTPErrorStill500() async {
        var codec = HTTP1Codec(handler: { _ in throw TestError("boom") })
        var bytes = ByteBufferAllocator().buffer(capacity: 64)
        bytes.writeString("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        codec.feed(bytes)

        let response = await codec.parseAndDispatch()
        #expect(response != nil)

        let body = response!.headerBuffer.getString(
            at: 0, length: response!.headerBuffer.readableBytes
        ) ?? ""
        #expect(body.contains("500 Internal Server Error"))
        #expect(!body.contains("404"))
    }

    // MARK: - HTTPError does not affect happy path

    @Test("Handler that does not throw still works")
    func happyPathUnaffected() async {
        var codec = HTTP1Codec(handler: { _ in HTTPResponse.plaintext("ok") })
        var bytes = ByteBufferAllocator().buffer(capacity: 64)
        bytes.writeString("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        codec.feed(bytes)

        let response = await codec.parseAndDispatch()
        #expect(response != nil)
        #expect(response!.keepAlive == true)
    }
}

private struct TestError: Error {
    let message: String
    init(_ m: String) { self.message = m }
}
