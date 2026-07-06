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
        #expect(HTTPMethod() == .other)
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
        let status = HTTPStatus(599, reasonPhrase: "Server-Side Flood")
        #expect(status.code == 599)
        #expect(status.reasonPhrase == "Server-Side Flood")
    }

    @Test func unknownCodeGetsUnknownReason() {
        #expect(HTTPStatus(789).reasonPhrase == "Unknown")
    }
}
