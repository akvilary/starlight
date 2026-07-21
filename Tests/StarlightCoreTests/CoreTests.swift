//===----------------------------------------------------------------------===//
//
//  CoreTests.swift
//  StarlightCoreTests
//
//===----------------------------------------------------------------------===//

import Testing
import StarlightCore
import HTTP

@Suite("Extractors + IntoResponse")
struct CoreTests {

    @Test("IntoResponse: () renders a 200 with empty body")
    func unitResponse() async throws {
        let response = Unit.shared.intoResponse()
        #expect(response.status == .ok)
        #expect(response.body.isEmpty)
    }

    @Test("IntoResponse: String renders text/plain")
    func stringResponse() async throws {
        let response = "hello".intoResponse()
        #expect(response.status == .ok)
        #expect(response.headers.first(for: .contentType)?.description == "text/plain; charset=utf-8")
        #expect(String(decoding: response.body.bytes, as: UTF8.self) == "hello")
    }

    @Test("Method extractor yields the request method")
    func methodExtractor() async throws {
        var parts = RequestParts<Body>(
            Request<Body>(method: .POST, uri: Uri("/"))
        )
        let method = try await Method.fromRequestParts(&parts, state: AnySendable())
        #expect(method == .POST)
    }

    @Test("HeaderMap extractor yields request headers")
    func headerMapExtractor() async throws {
        var headers = HeaderMap()
        headers.insert(.host, "example.com")
        var parts = RequestParts<Body>(
            Request<Body>(method: .GET, uri: Uri("/"), headers: headers)
        )
        let extracted = try await HeaderMap.fromRequestParts(&parts, state: AnySendable())
        #expect(extracted.first(for: .host)?.description == "example.com")
    }
}
