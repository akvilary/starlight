//===----------------------------------------------------------------------===//
//
//  MiddlewareTests.swift
//  StarlightRoutingTests (re-used for middleware tests)
//
//  Tests for TraceLayer, TimeoutLayer, CorsLayer.
//
//===----------------------------------------------------------------------===//

import Testing
import Foundation
import HTTP
import Synchronization
import StarlightCore
import StarlightExtractors
import StarlightRouting
import StarlightMiddleware
import Prism

fileprivate func fixed(_ s: String) -> HandlerEndpoint {
    BoxService { _ in .plain(s) }
}

@Suite("Middleware: Trace / Timeout / Cors / RateLimit")
struct MiddlewareTests {

    // MARK: - TraceLayer

    @Test("TraceLayer logs request and response")
    func traceLogging() async throws {
        let counter = Counter()
        let config = TraceConfig(
            onRequest: { _, _ in _ = counter.increment() },
            onResponse: { _, _, _, _ in _ = counter.increment() }
        )
        let router = Router(state: NoState())
            .get("/", fixed("ok"))
            .layer(TraceLayer(config: config).asLayer())

        let req = HTTP.Request(method: .GET, uri: Uri("/"))
        _ = try await router.call(req)

        // onRequest + onResponse = 2 calls
        #expect(counter.load() == 2)
    }

    // MARK: - TimeoutLayer

    @Test("TimeoutLayer returns 504 when handler exceeds duration")
    func timeoutExceeded() async throws {
        let slowService: HandlerEndpoint = BoxService { (_: HTTP.Request) -> HTTP.Response in
            try? await Task.sleep(for: .seconds(10))
            return .plain("done")
        }

        let layered = TimeoutLayer(duration: .milliseconds(50)).asLayer()
            .layer(slowService)

        let req = HTTP.Request(method: .GET, uri: Uri("/"))
        let response = try await layered.call(req)
        #expect(response.status == StatusCode.gatewayTimeout)
    }

    @Test("TimeoutLayer passes through when handler is fast")
    func timeoutPassThrough() async throws {
        let fastService: HandlerEndpoint = BoxService { _ in
            HTTP.Response.plain("fast")
        }

        let layered = TimeoutLayer(duration: .seconds(10)).asLayer()
            .layer(fastService)

        let req = HTTP.Request(method: .GET, uri: Uri("/"))
        let response = try await layered.call(req)
        #expect(response.status == StatusCode.ok)
        if case .buffered(let b) = response.body {
            #expect(String(decoding: b, as: UTF8.self) == "fast")
        }
    }

    // MARK: - CorsLayer

    @Test("CORS preflight (OPTIONS + Origin + ACRM)")
    func corsPreflight() async throws {
        let router = Router(state: NoState())
            .get("/api", fixed("data"))
        let service = CorsLayer().asLayer().layer(BoxService(router))

        var headers = HeaderMap()
        headers.insert(.origin, "https://example.com")
        headers.insert(.accessControlRequestMethod, "DELETE")
        let req = HTTP.Request(
            method: .OPTIONS, uri: Uri("/api"), headers: headers
        )
        let response = try await service.call(req)
        #expect(response.status == .noContent)
        #expect(response.headers.first(for: .accessControlAllowOrigin) != nil)
    }

    @Test("Non-preflight OPTIONS forwarded to handler")
    func corsNonPreflightOptions() async throws {
        let router = Router(state: NoState())
            .get("/api", fixed("data"))
        let service = CorsLayer().asLayer().layer(BoxService(router))

        // OPTIONS with Origin but NO Access-Control-Request-Method →
        // not a preflight → forwarded to Router → 405 (no OPTIONS handler).
        var headers = HeaderMap()
        headers.insert(.origin, "https://example.com")
        let req = HTTP.Request(method: .OPTIONS, uri: Uri("/api"), headers: headers)
        let response = try await service.call(req)
        // NOT 204 (preflight) — proves the request reached the Router.
        #expect(response.status != .noContent)
    }

    @Test("Vary: Origin on normal response")
    func corsVaryOrigin() async throws {
        let router = Router(state: NoState())
            .get("/api", fixed("data"))
        let service = CorsLayer().asLayer().layer(BoxService(router))

        let req = HTTP.Request(method: .GET, uri: Uri("/api"))
        let response = try await service.call(req)
        let vary = response.headers.first(for: .vary)?.description ?? ""
        #expect(vary.contains("Origin"))
    }

    @Test("CORS preflight rejects disallowed origin")
    func corsPreflightDisallowed() async throws {
        let config = CorsConfig(allowedOrigins: ["https://good.com"])
        let router = Router(state: NoState())
            .get("/api", fixed("data"))
        let service = CorsLayer(config: config).asLayer().layer(BoxService(router))

        var headers = HeaderMap()
        headers.insert(.origin, "https://evil.com")
        headers.insert(.accessControlRequestMethod, "DELETE")
        let req = HTTP.Request(method: .OPTIONS, uri: Uri("/api"), headers: headers)
        let response = try await service.call(req)
        #expect(response.status == .forbidden)
        #expect(response.headers.first(for: .accessControlAllowMethods) == nil)
    }

    @Test("CorsLayer restricts origins when configured")
    func corsRestrictedOrigin() async throws {
        let config = CorsConfig(allowedOrigins: ["https://allowed.com"])
        let router = Router(state: NoState())
            .get("/api", fixed("data"))
        let service = CorsLayer(config: config).asLayer().layer(BoxService(router))

        // Allowed origin
        var headers = HeaderMap()
        headers.insert(.origin, "https://allowed.com")
        let req1 = HTTP.Request(method: .GET, uri: Uri("/api"), headers: headers)
        let resp1 = try await service.call(req1)
        #expect(resp1.headers.first(for: .accessControlAllowOrigin)?.description == "https://allowed.com")

        // Disallowed origin
        var headers2 = HeaderMap()
        headers2.insert(.origin, "https://evil.com")
        let req2 = HTTP.Request(method: .GET, uri: Uri("/api"), headers: headers2)
        let resp2 = try await service.call(req2)
        #expect(resp2.headers.first(for: .accessControlAllowOrigin) == nil)
    }

    // MARK: - RateLimitLayer

    @Test("RateLimiter allows up to maxRequests then blocks")
    func rateLimitAllowsThenBlocks() {
        let limiter = RateLimiter(maxRequests: 3, windowDuration: .seconds(60))
        #expect(limiter.allow("ip1"))  // 1
        #expect(limiter.allow("ip1"))  // 2
        #expect(limiter.allow("ip1"))  // 3
        #expect(!limiter.allow("ip1")) // 4 — blocked
    }

    @Test("RateLimiter tracks keys independently")
    func rateLimitIndependentKeys() {
        let limiter = RateLimiter(maxRequests: 1)
        #expect(limiter.allow("ip1"))
        #expect(!limiter.allow("ip1"))
        #expect(limiter.allow("ip2"))  // different IP — own bucket
        #expect(!limiter.allow("ip2"))
    }

    @Test("RateLimitLayer returns 429 when exceeded")
    func rateLimitLayerReturns429() async throws {
        let limiter = RateLimiter(maxRequests: 2)
        let router = Router(state: NoState()).get("/", fixed("ok"))
        let service = RateLimitLayer(
            limiter: limiter,
            keyExtractor: { _ in "test-key" }
        ).asLayer().layer(BoxService(router))

        // First two requests OK
        let req = HTTP.Request(method: .GET, uri: Uri("/"))
        let resp1 = try await service.call(req)
        #expect(resp1.status == StatusCode.ok)
        let resp2 = try await service.call(req)
        #expect(resp2.status == StatusCode.ok)

        // Third — blocked
        let resp3 = try await service.call(req)
        #expect(resp3.status == StatusCode.tooManyRequests)
    }
}

/// Re-used from RouterTests.
fileprivate final class Counter: @unchecked Sendable {
    private let value = Atomic<Int>(0)
    @discardableResult
    func increment() -> Int {
        value.wrappingAdd(1, ordering: .relaxed).oldValue
    }
    func load() -> Int { value.load(ordering: .relaxed) }
}
