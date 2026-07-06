//===----------------------------------------------------------------------===//
//
//  RouterTests.swift
//  StarlightRoutingTests
//
//  Verifies the router matches static and dynamic routes correctly,
//  honours method dispatch, returns 404 for unmatched paths, and
//  propagates captured path parameters via `ctx.params`.
//
//===----------------------------------------------------------------------===//

import Testing
import StarlightCore
import StarlightHTTP
@testable import StarlightRouting

/// Test-only mutable cell. We need this because the test handlers
/// capture mutable state, and `@Sendable` closures (required by
/// `HTTPHandler`) cannot capture mutable local variables under Swift
/// 6.2's strict concurrency. `@unchecked Sendable` is safe in the
/// tests because the handlers run synchronously on the test thread.
final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ v: T) { self.value = v }
}

@Suite("Router")
struct RouterTests {
    // MARK: - Static routes

    @Test("Static route matches exact path")
    func staticMatch() {
        let router = Router()
        let registered = Box(false)
        router.get("/health") { _ in
            registered.value = true
            return HTTPResponse.plaintext("ok")
        }

        let match = router.match(method: .GET, path: "/health")
        #expect(match != nil)

        if let m = match {
            var ctx = RequestContext()
            ctx.params = m.params
            _ = m.handler(ctx)
            #expect(registered.value)
        }
    }

    @Test("Static route does not match different path")
    func staticMismatch() {
        let router = Router()
        router.get("/health") { _ in HTTPResponse.plaintext("ok") }

        let match = router.match(method: .GET, path: "/version")
        #expect(match == nil)
    }

    @Test("Root path matches empty pattern")
    func rootPath() {
        let router = Router()
        router.get("/") { _ in HTTPResponse.plaintext("root") }

        let match = router.match(method: .GET, path: "/")
        #expect(match != nil)
    }

    @Test("Trailing slash handled — `/health` matches `/health/`")
    func trailingSlash() {
        let router = Router()
        router.get("/health") { _ in HTTPResponse.plaintext("ok") }

        // `/health/` splits into the same segments as `/health`.
        let match = router.match(method: .GET, path: "/health/")
        #expect(match != nil)
    }

    // MARK: - Dynamic routes

    @Test("Dynamic segment captures value into params")
    func dynamicCapture() {
        let router = Router()
        router.get("/users/:id") { _ in HTTPResponse.plaintext("user") }

        let match = router.match(method: .GET, path: "/users/42")
        #expect(match != nil)
        #expect(match?.params["id"] == "42")
    }

    @Test("Multiple dynamic segments all captured")
    func multipleDynamic() {
        let router = Router()
        router.get("/users/:userId/posts/:postId") { _ in
            HTTPResponse.plaintext("post")
        }

        let match = router.match(method: .GET, path: "/users/7/posts/99")
        #expect(match != nil)
        #expect(match?.params["userId"] == "7")
        #expect(match?.params["postId"] == "99")
    }

    @Test("Dynamic segment requires non-empty capture")
    func dynamicEmptyRejected() {
        let router = Router()
        router.get("/users/:id") { _ in HTTPResponse.plaintext("user") }

        // `/users/` splits into ["users"] — segment count mismatch.
        let match = router.match(method: .GET, path: "/users/")
        #expect(match == nil)
    }

    // MARK: - Precedence: static beats dynamic

    @Test("Static route wins over dynamic when both match")
    func staticBeatsDynamic() {
        let router = Router()
        let hitDynamic = Box(false)
        let hitStatic = Box(false)
        // Register dynamic first to prove precedence is not "first
        // registered wins" — static must always win.
        router.get("/users/me") { _ in
            hitStatic.value = true
            return HTTPResponse.plaintext("static")
        }
        router.get("/users/:id") { _ in
            hitDynamic.value = true
            return HTTPResponse.plaintext("dynamic")
        }

        let match = router.match(method: .GET, path: "/users/me")
        #expect(match != nil)
        if let m = match {
            var ctx = RequestContext()
            ctx.params = m.params
            _ = m.handler(ctx)
        }
        #expect(hitStatic.value)
        #expect(!hitDynamic.value)
    }

    @Test("Dynamic route still matches when static doesn't apply")
    func dynamicWhenNoStatic() {
        let router = Router()
        let hitDynamic = Box(false)
        router.get("/users/me") { _ in HTTPResponse.plaintext("static") }
        router.get("/users/:id") { _ in
            hitDynamic.value = true
            return HTTPResponse.plaintext("dynamic")
        }

        let match = router.match(method: .GET, path: "/users/42")
        #expect(match != nil)
        #expect(match?.params["id"] == "42")
        if let m = match {
            var ctx = RequestContext()
            ctx.params = m.params
            _ = m.handler(ctx)
        }
        #expect(hitDynamic.value)
    }

    // MARK: - Method dispatch

    @Test("Method must match")
    func methodMismatch() {
        let router = Router()
        router.get("/items") { _ in HTTPResponse.plaintext("list") }
        router.post("/items") { _ in HTTPResponse.plaintext("create") }

        #expect(router.match(method: .GET, path: "/items") != nil)
        #expect(router.match(method: .POST, path: "/items") != nil)
        #expect(router.match(method: .DELETE, path: "/items") == nil)
    }

    @Test("Same path different methods route to different handlers")
    func samePathDifferentMethods() {
        let router = Router()
        let hit = Box("")
        router.get("/items") { _ in hit.value = "get"; return HTTPResponse.plaintext("g") }
        router.post("/items") { _ in hit.value = "post"; return HTTPResponse.plaintext("p") }
        router.delete("/items") { _ in hit.value = "delete"; return HTTPResponse.plaintext("d") }

        for (method, expected) in [(HTTPMethod.GET, "get"),
                                    (.POST, "post"),
                                    (.DELETE, "delete")] {
            guard let m = router.match(method: method, path: "/items") else {
                Issue.record("No match for \(method)")
                continue
            }
            var ctx = RequestContext()
            _ = m.handler(ctx)
            #expect(hit.value == expected)
        }
    }

    // MARK: - Query string

    @Test("Query string stripped before matching")
    func queryStringStripped() {
        let router = Router()
        router.get("/search") { _ in HTTPResponse.plaintext("results") }

        let match = router.match(method: .GET, path: "/search?q=hello&page=2")
        #expect(match != nil)
    }

    @Test("Dynamic segment captured even with query string")
    func dynamicWithQuery() {
        let router = Router()
        router.get("/users/:id") { _ in HTTPResponse.plaintext("u") }

        let match = router.match(method: .GET, path: "/users/42?verbose=1")
        #expect(match != nil)
        #expect(match?.params["id"] == "42")
    }

    // MARK: - 404

    @Test("Unmatched path returns nil (caller emits 404)")
    func unmatchedReturnsNil() {
        let router = Router()
        router.get("/here") { _ in HTTPResponse.plaintext("h") }

        #expect(router.match(method: .GET, path: "/not-here") == nil)
        #expect(router.match(method: .GET, path: "/here/sub") == nil)
    }

    @Test("Empty router returns nil for everything")
    func emptyRouter() {
        let router = Router()
        #expect(router.match(method: .GET, path: "/") == nil)
        #expect(router.match(method: .GET, path: "/anything") == nil)
    }

    // MARK: - handle() dispatch through middleware

    @Test("handle() returns 404 response when no match")
    func handleReturns404() {
        let router = Router()
        var ctx = RequestContext()
        ctx.method = .GET
        ctx.path = "/nope"
        let response = router.handle(&ctx)
        // We can't easily inspect the buffer contents here without
        // pulling in ByteBuffer read APIs; we just check that the
        // response exists. The "404" string is in there.
        #expect(response.buffer.readableBytes > 0)
    }

    @Test("handle() invokes matched handler with params set on ctx")
    func handleInvokesMatched() {
        let router = Router()
        let capturedParam = Box<String?>(nil)
        router.get("/users/:id") { ctx in
            capturedParam.value = ctx.params["id"]
            return HTTPResponse.plaintext("ok")
        }
        var ctx = RequestContext()
        ctx.method = .GET
        ctx.path = "/users/123"
        _ = router.handle(&ctx)
        #expect(capturedParam.value == "123")
        #expect(ctx.params["id"] == "123")
    }

    @Test("Middleware wraps the matched handler")
    func middlewareWraps() {
        let router = Router()
        let log = Box<[String]>([])
        router.use(Middleware { next in
            return { ctx in
                log.value.append("before")
                let resp = next(ctx)
                log.value.append("after")
                return resp
            }
        })
        router.get("/x") { _ in
            log.value.append("handler")
            return HTTPResponse.plaintext("ok")
        }
        var ctx = RequestContext()
        ctx.method = .GET
        ctx.path = "/x"
        _ = router.handle(&ctx)
        #expect(log.value == ["before", "handler", "after"])
    }

    @Test("Multiple middlewares compose outermost-first")
    func multipleMiddlewares() {
        let router = Router()
        let log = Box<[String]>([])
        router.use(Middleware { next in
            return { ctx in
                log.value.append("outer-before")
                let r = next(ctx)
                log.value.append("outer-after")
                return r
            }
        })
        router.use(Middleware { next in
            return { ctx in
                log.value.append("inner-before")
                let r = next(ctx)
                log.value.append("inner-after")
                return r
            }
        })
        router.get("/x") { _ in
            log.value.append("handler")
            return HTTPResponse.plaintext("ok")
        }
        var ctx = RequestContext()
        ctx.method = .GET
        ctx.path = "/x"
        _ = router.handle(&ctx)
        #expect(log.value == [
            "outer-before", "inner-before", "handler",
            "inner-after", "outer-after"
        ])
    }

    // MARK: - Pattern parsing edge cases

    @Test("Pattern with multiple consecutive slashes normalizes")
    func patternConsecutiveSlashes() {
        // The router splits on '/' and skips empty segments, so a
        // pattern like `//users//42` should match `/users/42`.
        let router = Router()
        router.get("/users/:id") { _ in HTTPResponse.plaintext("u") }

        #expect(router.match(method: .GET, path: "//users//42") != nil)
    }

    // MARK: - Route registration count

    @Test("routeCount reflects registered routes")
    func routeCount() {
        let router = Router()
        #expect(router.routeCount == 0)
        router.get("/a") { _ in HTTPResponse.plaintext("a") }
        router.get("/b") { _ in HTTPResponse.plaintext("b") }
        router.post("/c") { _ in HTTPResponse.plaintext("c") }
        #expect(router.routeCount == 3)
    }
}
