//===----------------------------------------------------------------------===//
//
//  ExtractorTests.swift
//  StarlightRoutingTests
//
//  Tests for the new Phase 1.4 extractors: Bytes, Form, ConnectInfo.
//
//===----------------------------------------------------------------------===//

import Testing
import Foundation
import HTTP
import StarlightCore
import StarlightExtractors
import StarlightRouting
import StarlightTower

@Suite("Phase 1.4 extractors")
struct ExtractorTests {

    // MARK: - Bytes

    @Test("Bytes extractor drains the body")
    func bytesExtractor() async throws {
        let request = HTTP.Request<Body>(
            method: .POST,
            uri: Uri("/"),
            body: .buffered([0x68, 0x69])  // "hi"
        )
        let bytes = try await Bytes.fromRequest(request, state: AnySendable())
        #expect(String(decoding: bytes.value, as: UTF8.self) == "hi")
    }

    @Test("Bytes IntoResponse round-trips")
    func bytesResponse() {
        let bytes = Bytes([0x68, 0x69])
        let response = bytes.intoResponse()
        if case .buffered(let b) = response.body {
            #expect(b == [0x68, 0x69])
        } else {
            Issue.record("expected .buffered body")
        }
        #expect(response.headers.first(for: .contentLength)?.description == "2")
    }

    // MARK: - Form

    @Test("Form extractor decodes urlencoded body")
    func formExtractor() async throws {
        var headers = HeaderMap()
        headers.insert(.contentType, "application/x-www-form-urlencoded")
        let body = "name=alice&age=30"
        let request = HTTP.Request<Body>(
            method: .POST,
            uri: Uri("/login"),
            headers: headers,
            body: .buffered(Array(body.utf8))
        )

        struct Login: Decodable, Sendable {
            let name: String
            let age: Int
        }

        let form: Form<Login> = try await Form.fromRequest(request, state: AnySendable())
        #expect(form.value.name == "alice")
        #expect(form.value.age == 30)
    }

    @Test("Form extractor rejects wrong content-type")
    func formRejectsWrongContentType() async throws {
        var headers = HeaderMap()
        headers.insert(.contentType, "application/json")
        let request = HTTP.Request<Body>(
            method: .POST,
            uri: Uri("/login"),
            headers: headers,
            body: .empty
        )

        struct Login: Decodable, Sendable { let name: String }

        do {
            _ = try await Form<Login>.fromRequest(request, state: AnySendable())
            Issue.record("expected ExtractionRejection")
        } catch {
            // expected
        }
    }

    @Test("Form extractor decodes URL-encoded values")
    func formUrlDecoding() async throws {
        var headers = HeaderMap()
        headers.insert(.contentType, "application/x-www-form-urlencoded")
        // %20 = space, + = space, %2B = literal +
        let body = "name=alice+smith&greeting=hello%20world&plus=a%2Bb"
        let request = HTTP.Request<Body>(
            method: .POST,
            uri: Uri("/"),
            headers: headers,
            body: .buffered(Array(body.utf8))
        )

        struct FormPayload: Decodable, Sendable {
            let name: String
            let greeting: String
            let plus: String
        }

        let f: Form<FormPayload> = try await Form<FormPayload>.fromRequest(request, state: AnySendable())
        #expect(f.value.name == "alice smith")
        #expect(f.value.greeting == "hello world")
        #expect(f.value.plus == "a+b")
    }

    // MARK: - ConnectInfo

    @Test("ConnectInfo reads from extensions")
    func connectInfoExtractor() async throws {
        var extensions = Extensions()
        extensions.insert(ConnectInfo(peerAddress: "127.0.0.1:54321"))
        let req = HTTP.Request<Body>(
            method: .GET,
            uri: Uri("/"),
            body: Body.empty,
            extensions: extensions
        )
        var parts = RequestParts<Body>(req)
        let info = try await ConnectInfo.fromRequestParts(&parts, state: AnySendable())
        #expect(info.peerAddress == "127.0.0.1:54321")
    }

    @Test("ConnectInfo throws if not set")
    func connectInfoMissing() async throws {
        var parts = RequestParts<Body>(
            HTTP.Request<Body>(method: .GET, uri: Uri("/"), body: .empty)
        )
        do {
            _ = try await ConnectInfo.fromRequestParts(&parts, state: AnySendable())
            Issue.record("expected ExtractionRejection")
        } catch {
            // expected
        }
    }

    @Test("setConnectInfo helper populates extensions")
    func setConnectInfoHelper() {
        var request = HTTP.Request<Body>(method: .GET, uri: Uri("/"))
        setConnectInfo("10.0.0.1:80", on: &request)
        #expect(request.extensions.get(ConnectInfo.self)?.peerAddress == "10.0.0.1:80")
    }
}
