//===----------------------------------------------------------------------===//
//
//  RouterTests.swift
//  StarlightRoutingTests
//
//  Tests for Router<S>.nest, .merge, .layer, .route_layer — the
//  axum::routing::Router::* API surface.
//
//===----------------------------------------------------------------------===//

import Testing
import Foundation
import HTTP
import Synchronization
import StarlightCore
import StarlightExtractors
import StarlightRouting
import Pylon
@testable import StarlightRouting

// MARK: - Test helpers

/// Test-only Service that just returns a fixed string.
fileprivate func fixed(_ s: String) -> HandlerEndpoint {
    BoxService { _ in .plain(s) }
}

fileprivate func call(_ router: Router<NoState>, path: String) async throws -> String {
    let req = HTTP.Request(method: .GET, uri: Uri(path))
    let resp = try await router.call(req)
    return if case .buffered(let b) = resp.body {
        String(decoding: b, as: UTF8.self)
    } else { "" }
}

fileprivate func call(_ router: Router<NoState>, method: Method, path: String) async throws -> HTTP.Response {
    let req = HTTP.Request(method: method, uri: Uri(path))
    return try await router.call(req)
}

/// Atomic counter — Sendable, safe to mutate from concurrent code.
fileprivate final class Counter: @unchecked Sendable {
    private let value = Atomic<Int>(0)
    @discardableResult
    func increment() -> Int {
        value.wrappingAdd(1, ordering: .relaxed).oldValue
    }
    func load() -> Int { value.load(ordering: .relaxed) }
}

// MARK: - nest tests

@Suite("Router.nest")
struct NestTests {

    @Test("Nest a router under a prefix")
    func basicNest() async throws {
        let api = Router(state: NoState())
            .get("/users", fixed("users"))
            .get("/posts", fixed("posts"))

        let app = Router(state: NoState())
            .get("/", fixed("root"))
            .nest("/api", api)

        #expect(try await call(app, path: "/") == "root")
        #expect(try await call(app, path: "/api/users") == "users")
        #expect(try await call(app, path: "/api/posts") == "posts")
    }

    @Test("Nest with trailing slash in prefix")
    func trailingSlash() async throws {
        let api = Router(state: NoState())
            .get("/users", fixed("u"))

        let app = Router(state: NoState())
            .nest("/api/", api)

        #expect(try await call(app, path: "/api/users") == "u")
    }

    @Test("Nest at prefix + nested root path")
    func nestAtRoot() async throws {
        let inner = Router(state: NoState())
            .get("/", fixed("inner-root"))

        let app = Router(state: NoState())
            .nest("/api", inner)

        #expect(try await call(app, path: "/api") == "inner-root")
    }
}

// MARK: - merge tests

@Suite("Router.merge")
struct MergeTests {

    @Test("Merge two routers")
    func basicMerge() async throws {
        let a = Router(state: NoState()).get("/a", fixed("A"))
        let b = Router(state: NoState()).get("/b", fixed("B"))

        let app = a.merge(b)

        #expect(try await call(app, path: "/a") == "A")
        #expect(try await call(app, path: "/b") == "B")
    }
}

// MARK: - layer tests

@Suite("Router.layer / route_layer")
struct LayerTests {

    @Test("layer wraps every route")
    func layerAllRoutes() async throws {
        let counter = Counter()

        let router = Router(state: NoState())
            .get("/a", fixed("a"))
            .get("/b", fixed("b"))
            .layer(Layer { inner in
                BoxService { req in
                    _ = counter.increment()
                    return try await inner.call(req)
                }
            })

        _ = try await call(router, path: "/a")
        _ = try await call(router, path: "/b")

        #expect(counter.load() == 2)
    }

    @Test("route_layer applies to all routes registered so far")
    func routeLayerScoping() async throws {
        let counter = Counter()
        let authLayer = Layer<HTTP.Request, HTTP.Response> { inner in
            BoxService { req in
                _ = counter.increment()
                return try await inner.call(req)
            }
        }

        // axum semantics: route_layer applies to ALL routes registered
        // BEFORE this call. Routes added AFTER are not wrapped.
        let router = Router(state: NoState())
            .get("/public", fixed("p"))
            .route_layer(authLayer)
            .get("/secret", fixed("s"))

        // /public was registered BEFORE route_layer → wrapped.
        _ = try await call(router, path: "/public")
        #expect(counter.load() == 1)

        // /secret was registered AFTER route_layer → NOT wrapped.
        // (Note: our current implementation wraps ALL routes when
        // route_layer is called, matching the layer() semantics. The
        // "after route_layer" routes are added later and bypass it.)
        _ = try await call(router, path: "/secret")
        // Since route_layer was called between the two gets, and our
        // impl is "apply to current routes", /public is wrapped but
        // /secret (added after) is not.
        #expect(counter.load() == 1)
    }

    // MARK: - Route merging (A5)

    @Test("Same path different methods merge correctly")
    func samePathDifferentMethods() async throws {
        let router = Router(state: NoState())
            .get("/users") { _ in .plain("GET users") }
            .post("/users") { _ in .plain("POST users") }

        let getResp = try await call(router, method: .GET, path: "/users")
        #expect(getResp.status == .ok)

        let postResp = try await call(router, method: .POST, path: "/users")
        #expect(postResp.status == .ok)

        // PUT has no handler → 405.
        let putResp = try await call(router, method: .PUT, path: "/users")
        #expect(putResp.status == .methodNotAllowed)
    }

    @Test("Three methods on same path all work")
    func threeMethodsSamePath() async throws {
        let router = Router(state: NoState())
            .get("/x") { _ in .plain("ok") }
            .post("/x") { _ in .plain("ok") }
            .delete("/x") { _ in .plain("ok") }

        #expect(try await call(router, method: .GET, path: "/x").status == .ok)
        #expect(try await call(router, method: .POST, path: "/x").status == .ok)
        #expect(try await call(router, method: Method.DELETE, path: "/x").status == .ok)
    }
}
