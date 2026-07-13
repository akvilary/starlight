//===----------------------------------------------------------------------===//
//
//  HTTPMethodTests.swift
//  StarlightHTTPTests
//
//===----------------------------------------------------------------------===//

import Testing
@testable import StarlightHTTP

@Suite("HTTPMethod")
struct HTTPMethodTests {
    @Test func defaultInitIsOther() {
        #expect(HTTPMethod() == .other(raw: ""))
    }
}

@Suite("HTTPStatus")
struct HTTPStatusTests {
    @Test func reasonPhraseDefaults() {
        #expect(HTTPStatus.ok.reasonPhrase == "OK")
        #expect(HTTPStatus.notFound.reasonPhrase == "Not Found")
        #expect(HTTPStatus.internalServerError.reasonPhrase == "Internal Server Error")
    }

    @Test func customReasonPhrase() {
        let status = HTTPStatus(503, reasonPhrase: "Service Unavailable")
        #expect(status.code == 503)
        #expect(status.reasonPhrase == "Service Unavailable")
    }

    @Test func customCodeGetsDefaultReason() {
        #expect(HTTPStatus(418).reasonPhrase == "Unknown")
    }
}
