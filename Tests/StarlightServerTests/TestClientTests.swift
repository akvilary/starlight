//===----------------------------------------------------------------------===//
//
//  TestClientTests.swift
//  StarlightServerTests
//
//===----------------------------------------------------------------------===//

import Testing
import Foundation
import HTTP
import StarlightCore
import StarlightExtractors
import StarlightRouting
import StarlightServer
import HTTPPrism

@Suite("TestClient")
struct TestClientTests {

    fileprivate let router = Router(state: NoState())
        .get("/") { _ in .plain("hello") }
        .get("/users/:id") { req in
            // Read matched path params from extensions
            if let params = req.extensions.get(MatchedPathParams.self),
               let id = params.params.get("id") {
                return .plain("user \(id)")
            }
            return .plain("no id", status: .badRequest)
        }
        .post("/echo") { req in
            let body = req.uri.pathString
            return .plain("echo: \(body)")
        }

    @Test("GET / returns hello")
    func getRoot() async throws {
        let client = TestClient(router)
        let response = try await client.get("/")
        #expect(response.status == StatusCode.ok)
        let body = await response.bodyString()
        #expect(body == "hello")
    }

    @Test("GET /users/:id extracts param")
    func getPathParam() async throws {
        let client = TestClient(router)
        let response = try await client.get("/users/42")
        #expect(response.status == StatusCode.ok)
        let body = await response.bodyString()
        #expect(body == "user 42")
    }

    @Test("POST /echo returns body")
    func postEcho() async throws {
        let client = TestClient(router)
        let response = try await client.post("/echo", body: .buffered(Array("test".utf8)))
        #expect(response.status == StatusCode.ok)
    }

    @Test("GET unknown path returns 404")
    func getNotFound() async throws {
        let client = TestClient(router)
        let response = try await client.get("/nonexistent")
        #expect(response.status == StatusCode.notFound)
    }

    @Test("postJSON helper encodes body")
    func postJSONHelper() async throws {
        struct Payload: Encodable, Sendable, Decodable, Equatable { let name: String }
        let echoRouter = Router(state: NoState())
            .post("/data") { req in
                let bytes = try await req.body.collect()
                return .plain(String(decoding: bytes, as: UTF8.self))
            }

        let client = TestClient(echoRouter)
        let response = try await client.postJSON("/data", Payload(name: "alice"))
        #expect(response.status == StatusCode.ok)
        let body = await response.bodyString()
        #expect(body.contains("alice"))
    }
}
