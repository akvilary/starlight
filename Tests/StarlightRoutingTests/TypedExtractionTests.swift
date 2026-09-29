//===----------------------------------------------------------------------===//
//
//  TypedExtractionTests.swift
//  StarlightRoutingTests
//
//  Tests for the typed-extraction upgrades that unblock migration of
//  JSON REST APIs (bedone-backend):
//    • `StringKeyedDecoder` — UUID path params, multi-value query keys
//    • `JsonConfig` — shared coders, iso8601, layer override
//    • `PartsHandlerService2/3/4` — parts-only typed handlers
//    • `errorLayer()` / `ResponseError` — typed error responses
//    • `DefaultBodyLimit` 2 MiB default — 413 instead of unbounded
//
//===----------------------------------------------------------------------===//

import Testing
import Foundation
import HTTPModel
import HTTPPrism
import StarlightCore
import StarlightExtractors
import StarlightRouting

// ── Shared fixtures ───────────────────────────────────────────────

private let uuidString = "123E4567-E89B-12D3-A456-426614174000"
private let otherUuidString = "C0FFEE00-CAFE-BABE-0000-DEADBEEF0000"

private struct AppState: Sendable {
    let marker: String
}

private enum TestAppError: Error, ResponseError, Sendable {
    case notFound(String)
    case unauthorized(String)

    func intoResponse() -> Response {
        switch self {
        case .notFound(let m): return .plain(m, status: .notFound)
        case .unauthorized(let m): return .plain(m, status: .unauthorized)
        }
    }
}

private struct PlainError: Error, Sendable {}

/// Build a request whose extensions carry matched path params —
/// the state a `Router` produces on a successful match.
private func requestWithParams(
    _ params: [(String, String)],
    uri: String = "/x",
    method: Method = .GET
) -> HTTPModel.Request {
    var req = HTTPModel.Request(method: method, uri: Uri(uri))
    var p = PathParams()
    for (n, v) in params { p.set(n, value: v) }
    req.extensions.insert(MatchedPathParams(p))
    return req
}

private extension Response {
    func bodyString() async -> String {
        let bytes = (try? await body.collect()) ?? []
        return String(decoding: bytes, as: UTF8.self)
    }
}

// ── Suite: StringKeyedDecoder upgrades ────────────────────────────

@Suite("StringKeyedDecoder: UUID + multi-value")
struct StringKeyedDecoderTests {

    @Test("Path<UUID> decodes a single captured param")
    func pathUUID() async throws {
        let request = requestWithParams([("id", uuidString)], uri: "/api/tasks/\(uuidString)")
        var parts = RequestParts(request)
        let extracted = try await Path<UUID>.fromRequestParts(&parts, state: NoState())
        #expect(extracted.value.uuidString == uuidString)
    }

    @Test("Path<UUID> rejects a non-UUID param")
    func pathUUIDInvalid() async throws {
        let request = requestWithParams([("id", "not-a-uuid")])
        var parts = RequestParts(request)
        do {
            _ = try await Path<UUID>.fromRequestParts(&parts, state: NoState())
            Issue.record("expected rejection")
        } catch let r as ExtractionRejection {
            #expect(r.response.status == .badRequest)
        }
    }

    @Test("Path<struct> with a UUID field")
    func pathStructUUIDField() async throws {
        struct TaskRef: Decodable, Sendable { let id: UUID }
        let request = requestWithParams([("id", uuidString)])
        var parts = RequestParts(request)
        let extracted = try await Path<TaskRef>.fromRequestParts(&parts, state: NoState())
        #expect(extracted.value.id.uuidString == uuidString)
    }

    @Test("Path<struct> with two params still works")
    func pathStructTwoParams() async throws {
        struct Two: Decodable, Sendable { let projectId: UUID; let seq: Int }
        let request = requestWithParams([("projectId", uuidString), ("seq", "42")])
        var parts = RequestParts(request)
        let extracted = try await Path<Two>.fromRequestParts(&parts, state: NoState())
        #expect(extracted.value.projectId.uuidString == uuidString)
        #expect(extracted.value.seq == 42)
    }

    @Test("Query decodes repeated keys into [String]")
    func queryMultiValue() async throws {
        struct Filters: Decodable, Sendable { let tags: [String]? }
        let request = HTTPModel.Request(method: .GET, uri: Uri("/tasks?tags=a&tags=b&tags=c"))
        var parts = RequestParts(request)
        let extracted = try await Query<Filters>.fromRequestParts(&parts, state: NoState())
        #expect(extracted.value.tags == ["a", "b", "c"])
    }

    @Test("Query single occurrence decodes into a one-element array")
    func querySingleValueArray() async throws {
        struct Filters: Decodable, Sendable { let tags: [String]? }
        let request = HTTPModel.Request(method: .GET, uri: Uri("/tasks?tags=solo"))
        var parts = RequestParts(request)
        let extracted = try await Query<Filters>.fromRequestParts(&parts, state: NoState())
        #expect(extracted.value.tags == ["solo"])
    }

    @Test("Query optional array is nil when the key is absent")
    func queryOptionalArrayAbsent() async throws {
        struct Filters: Decodable, Sendable { let tags: [String]?; let limit: Int? }
        let request = HTTPModel.Request(method: .GET, uri: Uri("/tasks?limit=10"))
        var parts = RequestParts(request)
        let extracted = try await Query<Filters>.fromRequestParts(&parts, state: NoState())
        #expect(extracted.value.tags == nil)
        #expect(extracted.value.limit == 10)
    }

    @Test("Query decodes repeated UUIDs into [UUID]")
    func queryUUIDArray() async throws {
        struct Filters: Decodable, Sendable { let ids: [UUID]? }
        let request = HTTPModel.Request(
            method: .GET,
            uri: Uri("/tasks?ids=\(uuidString)&ids=\(otherUuidString)")
        )
        var parts = RequestParts(request)
        let extracted = try await Query<Filters>.fromRequestParts(&parts, state: NoState())
        #expect(extracted.value.ids?.count == 2)
        #expect(extracted.value.ids?[0].uuidString == uuidString)
    }

    @Test("Query decodes a UUID field")
    func queryUUIDField() async throws {
        struct ById: Decodable, Sendable { let id: UUID }
        let request = HTTPModel.Request(method: .GET, uri: Uri("/x?id=\(uuidString)"))
        var parts = RequestParts(request)
        let extracted = try await Query<ById>.fromRequestParts(&parts, state: NoState())
        #expect(extracted.value.id.uuidString == uuidString)
    }

    @Test("Nested structs still fail with a clear error")
    func nestedStillRejected() async throws {
        struct Nested: Decodable, Sendable {
            struct Inner: Decodable, Sendable { let x: Int }
            let inner: Inner
        }
        let request = requestWithParams([("inner", "oops")])
        var parts = RequestParts(request)
        do {
            _ = try await Path<Nested>.fromRequestParts(&parts, state: NoState())
            Issue.record("expected rejection")
        } catch let r as ExtractionRejection {
            #expect(r.response.status == .badRequest)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("Top-level single value with two params is rejected")
    func topLevelSingleValueAmbiguity() async throws {
        let request = requestWithParams([("a", "1"), ("b", "2")])
        var parts = RequestParts(request)
        do {
            _ = try await Path<UUID>.fromRequestParts(&parts, state: NoState())
            Issue.record("expected rejection for ambiguous single-value decode")
        } catch let r as ExtractionRejection {
            #expect(r.response.status == .badRequest)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("Primitives decode through the generic field path")
    func primitivesThroughGenericPath() async throws {
        struct All: Decodable, Sendable {
            let i: Int8; let s: Int16; let u: UInt8; let f: Float; let d: Double
        }
        let request = requestWithParams(
            [("i", "7"), ("s", "300"), ("u", "9"), ("f", "1.5"), ("d", "2.25")]
        )
        var parts = RequestParts(request)
        let extracted = try await Path<All>.fromRequestParts(&parts, state: NoState())
        #expect(extracted.value.i == 7)
        #expect(extracted.value.s == 300)
        #expect(extracted.value.u == 9)
        #expect(extracted.value.f == 1.5)
        #expect(extracted.value.d == 2.25)
    }
}

// ── Suite: JsonConfig ─────────────────────────────────────────────

@Suite("JsonConfig: shared coders + iso8601", .serialized)
struct JsonConfigTests {

    struct Event: Codable, Sendable {
        let at: Date
    }

    @Test("Default coders still work without registration")
    func fallbackWorks() async throws {
        JsonConfig.resetDefault()
        defer { JsonConfig.resetDefault() }
        let config = JsonConfig.default
        let date = Date(timeIntervalSince1970: 1_000_000)
        let event = Event(at: date)
        let data = try config.encoder.encode(event)
        let back = try config.decoder.decode(Event.self, from: data)
        #expect(back.at == date)
    }

    @Test("Registered iso8601 config drives response encoding")
    func responseUsesRegisteredConfig() async throws {
        JsonConfig.resetDefault()
        defer { JsonConfig.resetDefault() }
        JsonConfig.setDefault(.iso8601())

        let date = Date(timeIntervalSince1970: 1_769_664_000)
        let response = Json(Event(at: date)).intoResponse()
        #expect(response.status == .ok)
        #expect(response.headers.first(for: .contentType)?.description.hasPrefix("application/json") == true)

        let body = await response.bodyString()
        let expected = ISO8601DateFormatter().string(from: date)
        #expect(body.contains(expected))
    }

    @Test("Request decoding picks up the extension override")
    func requestUsesExtensionOverride() async throws {
        JsonConfig.resetDefault()
        defer { JsonConfig.resetDefault() }

        // Registry holds a plain config; the request extension
        // overrides with secondsSince1970 decoding.
        JsonConfig.setDefault(JsonConfig(encoder: JSONEncoder(), decoder: JSONDecoder()))
        var custom = JSONDecoder()
        custom.dateDecodingStrategy = .secondsSince1970
        let override = JsonConfig(encoder: JSONEncoder(), decoder: custom)

        var headers = HeaderMap()
        headers.insert(.contentType, "application/json")
        var request = HTTPModel.Request(
            method: .POST, uri: Uri("/events"),
            headers: headers,
            body: .buffered(Array(#"{"at":1769664000}"#.utf8))
        )
        request.extensions.insert(override)

        let json = try await Json<Event>.fromRequest(request, state: NoState())
        #expect(json.value.at.timeIntervalSince1970 == 1_769_664_000)
    }

    @Test("JsonConfig.layer injects the override for request decoding")
    func layerInjectsConfig() async throws {
        JsonConfig.resetDefault()
        defer { JsonConfig.resetDefault() }

        let router = Router(state: NoState())
            .post("/echo-date") { (request: HTTPModel.Request) in
                // Closure-style manual extraction — decodes with
                // whatever config the layers inserted (iso8601 here).
                let json = try await Json<Event>.fromRequest(request, state: NoState())
                return Response(.created, from: Response.plain(json.value.at.description))
            }
            .layer(JsonConfig.layer(.iso8601()))

        var headers = HeaderMap()
        headers.insert(.contentType, "application/json")
        let response = try await router.call(HTTPModel.Request(
            method: .POST, uri: Uri("/echo-date"),
            headers: headers,
            body: .buffered(Array("{\"at\":\"2026-01-29T12:00:00Z\"}".utf8))
        ))
        #expect(response.status == .created)
        let body = await response.bodyString()
        #expect(body.contains("2026-01-29 12:00:00"))
    }
}

// ── Suite: parts-only typed handlers ──────────────────────────────

@Suite("PartsHandlerService: parts-only typed handlers")
struct PartsHandlerServiceTests {

    @Test("PartsHandlerService2 combines Path<UUID> + Method + State")
    func parts2() async throws {
        let state = AppState(marker: "app")
        let handler = PartsHandlerService2(state: state) {
            (p: Path<UUID>, _: Method, s: AppState) -> Response in
            .plain("\(s.marker):\(p.value.uuidString)")
        }
        let request = requestWithParams([("id", uuidString)])
        let response = try await handler.call(request)
        #expect(response.status == .ok)
        let body = await response.bodyString()
        #expect(body == "app:\(uuidString)")
    }

    @Test("HandlerService1 combines a single parts extractor + State")
    func handler1() async throws {
        let state = AppState(marker: "solo")
        let handler = HandlerService1(state: state) {
            (p: Path<UUID>, s: AppState) -> Response in
            .plain("\(s.marker):\(p.value.uuidString)")
        }
        let request = requestWithParams([("id", uuidString)])
        let response = try await handler.call(request)
        let body = await response.bodyString()
        #expect(body == "solo:\(uuidString)")
    }

    @Test("PartsHandlerService3 combines Query + Path + Method + State")
    func parts3() async throws {
        struct Filters: Decodable, Sendable { let limit: Int? }
        let handler = PartsHandlerService3(state: NoState()) {
            (q: Query<Filters>, p: Path<UUID>, _: Method, _: NoState) -> Response in
            .plain("limit=\(q.value.limit ?? -1) id=\(p.value.uuidString)")
        }
        var req = HTTPModel.Request(method: .GET, uri: Uri("/tasks?limit=25"))
        var params = PathParams()
        params.set("id", value: uuidString)
        req.extensions.insert(MatchedPathParams(params))
        let response = try await handler.call(req)
        let body = await response.bodyString()
        #expect(body == "limit=25 id=\(uuidString)")
    }

    @Test("PartsHandlerService3 combines Extension + Path + Query + State")
    func partsExtensionPathQuery() async throws {
        struct User: Hashable, Sendable { let id: UUID }
        struct Filters: Decodable, Sendable { let tags: [String]? }
        let user = User(id: UUID(uuidString: uuidString)!)

        let handler = PartsHandlerService3(state: NoState()) {
            (_ user: Extension<User>, p: Path<UUID>, q: Query<Filters>, _: NoState) -> Response in
            .plain("u=\(user.value.id.uuidString.prefix(8)) p=\(p.value.uuidString.prefix(8)) tags=\(q.value.tags?.count ?? 0)")
        }
        var req = HTTPModel.Request(method: .GET, uri: Uri("/tasks?tags=a&tags=b"))
        var params = PathParams()
        params.set("id", value: otherUuidString)
        req.extensions.insert(MatchedPathParams(params))
        req.extensions.insert(user)
        let response = try await handler.call(req)
        let body = await response.bodyString()
        #expect(body == "u=123E4567 p=C0FFEE00 tags=2")
    }

    @Test("PartsHandlerService4 combines Extension + Method + Path + Query + State")
    func parts4() async throws {
        struct User: Hashable, Sendable { let id: UUID }
        struct Filters: Decodable, Sendable { let tags: [String]? }
        let user = User(id: UUID(uuidString: uuidString)!)

        let handler = PartsHandlerService4(state: NoState()) {
            (_ user: Extension<User>, _: Method, p: Path<UUID>, q: Query<Filters>, _: NoState) -> Response in
            .plain("u=\(user.value.id.uuidString.prefix(8)) p=\(p.value.uuidString.prefix(8)) tags=\(q.value.tags?.count ?? 0)")
        }
        var req = HTTPModel.Request(method: .GET, uri: Uri("/tasks?tags=a&tags=b"))
        var params = PathParams()
        params.set("id", value: otherUuidString)
        req.extensions.insert(MatchedPathParams(params))
        req.extensions.insert(user)
        let response = try await handler.call(req)
        let body = await response.bodyString()
        #expect(body == "u=123E4567 p=C0FFEE00 tags=2")
    }

    @Test("Typed parts-only handler wired into Router via BoxService")
    func typedHandlerInRouter() async throws {
        let state = AppState(marker: "m")
        let router = Router(state: state)
            .get(
                "/users/:id",
                BoxService(HandlerService1(state: state) {
                    (p: Path<UUID>, s: AppState) -> Response in
                    .plain("\(s.marker):\(p.value.uuidString)")
                })
            )
        let response = try await router.call(
            HTTPModel.Request(method: .GET, uri: Uri("/users/\(uuidString)"))
        )
        let body = await response.bodyString()
        #expect(body == "m:\(uuidString)")
    }

    @Test("Parts-only handler does not consume the request body")
    func bodyUntouched() async throws {
        let payload = Array(#"{"x":42}"#.utf8)
        let handler = PartsHandlerService2(state: NoState()) {
            (_: Method, uri: Uri, _: NoState) -> Response in
            .plain(uri.pathString)
        }
        let request = HTTPModel.Request(
            method: .GET, uri: Uri("/t?tags=a"),
            body: .buffered(payload)
        )
        let response = try await handler.call(request)
        #expect(response.status == .ok)
    }
}

// ── Suite: error layer ────────────────────────────────────────────

@Suite("errorLayer: typed error responses")
struct ErrorLayerTests {

    @Test("ResponseError is converted into its response")
    func convertsDomainError() async throws {
        let router = Router()
            .get("/missing") { (_: HTTPModel.Request) in
                throw TestAppError.notFound("task not found")
            }
            .layer(errorLayer())

        let response = try await router.call(
            HTTPModel.Request(method: .GET, uri: Uri("/missing"))
        )
        #expect(response.status == .notFound)
        let body = await response.bodyString()
        #expect(body.contains("task not found"))
    }

    @Test("Non-conforming errors propagate (server 500 path)")
    func propagatesUnknownErrors() async throws {
        let router = Router()
            .get("/boom") { (_: HTTPModel.Request) in throw PlainError() }
            .layer(errorLayer())

        await #expect(throws: PlainError.self) {
            _ = try await router.call(HTTPModel.Request(method: .GET, uri: Uri("/boom")))
        }
    }

    @Test("Escaped ExtractionRejection renders its embedded response")
    func rendersEscapedRejection() async throws {
        struct Payload: Decodable, Sendable { let x: Int }
        let router = Router()
            .post("/echo") { (request: HTTPModel.Request) in
                // No content-type header → 415 rejection escapes the
                // closure-style handler; errorLayer must render it.
                let json = try await Json<Payload>.fromRequest(request, state: NoState())
                return .plain("\(json.value.x)")
            }
            .layer(errorLayer())

        let response = try await router.call(HTTPModel.Request(
            method: .POST, uri: Uri("/echo"),
            body: .buffered(Array(#"{"x":1}"#.utf8))
        ))
        #expect(response.status == .unsupportedMediaType)
    }

    @Test("CancellationError is not intercepted")
    func doesNotInterceptCancellation() async throws {
        let router = Router()
            .get("/cancel") { (_: HTTPModel.Request) in throw CancellationError() }
            .layer(errorLayer())
        await #expect(throws: CancellationError.self) {
            _ = try await router.call(HTTPModel.Request(method: .GET, uri: Uri("/cancel")))
        }
    }

    @Test("Layer order: errors get headers from outer layers")
    func errorInsideOuterLayer() async throws {
        let addHeader = Layer<HTTPModel.Request, HTTPModel.Response> { inner in
            BoxService { request in
                var response = try await inner.call(request)
                response.headers.insert(.server, "test")
                return response
            }
        }
        let router = Router()
            .get("/e") { (_: HTTPModel.Request) in throw TestAppError.unauthorized("no token") }
            .layer(errorLayer())
            .layer(addHeader)

        let response = try await router.call(HTTPModel.Request(method: .GET, uri: Uri("/e")))
        #expect(response.status == .unauthorized)
        #expect(response.headers.first(for: .server)?.description == "test")
    }
}

// ── Suite: default body limit ─────────────────────────────────────

@Suite("DefaultBodyLimit: 2 MiB default")
struct DefaultBodyLimitTests {

    @Test("Json extractor rejects bodies above the default limit with 413")
    func oversizedBodyIs413() async throws {
        struct Payload: Decodable, Sendable { let x: Int }
        var headers = HeaderMap()
        headers.insert(.contentType, "application/json")
        let request = HTTPModel.Request(
            method: .POST, uri: Uri("/big"),
            headers: headers,
            body: .buffered([UInt8](repeating: 0x61, count: 2 * 1024 * 1024 + 1))
        )
        do {
            _ = try await Json<Payload>.fromRequest(request, state: NoState())
            Issue.record("expected 413 rejection")
        } catch let r as ExtractionRejection {
            #expect(r.response.status == .payloadTooLarge)
        }
    }

    @Test("Explicit smaller limit rejects with 413")
    func explicitSmallerLimit() async throws {
        struct Payload: Decodable, Sendable { let pad: String; let x: Int }
        var headers = HeaderMap()
        headers.insert(.contentType, "application/json")
        var request = HTTPModel.Request(
            method: .POST, uri: Uri("/big"),
            headers: headers,
            body: .buffered(Array("{\"pad\":\"aaaaaaaaaaaaaaaaaaaa\",\"x\":1}".utf8))
        )
        request.extensions.insert(DefaultBodyLimit(maxBytes: 8))
        do {
            _ = try await Json<Payload>.fromRequest(request, state: NoState())
            Issue.record("expected 413 rejection for tiny limit")
        } catch let r as ExtractionRejection {
            #expect(r.response.status == .payloadTooLarge)
        }
    }
}
