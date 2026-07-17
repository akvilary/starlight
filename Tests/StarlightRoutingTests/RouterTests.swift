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

/// Test-only dispatch helper — invokes the handler that the router
/// matched, so middleware composition can be verified without pulling
/// in the codec (which lives in StarlightServer). Mirrors what the
/// codec does on the hot path: match → set params → invoke handler.
@discardableResult
private func dispatch(
    _ router: Router, method: HTTPMethod, path: String
) async throws -> HTTPResponse? {
    var ctx = RequestContext()
    ctx.method = method
    ctx.setPath(path)
    guard let m = router.match(method: method, path: ctx.path) else {
        return nil
    }
    ctx.params = m.params
    switch m.handler {
    case .sync(let fn):
        return try fn(ctx)
    case .async(let fn):
        return try await fn(ctx)
    }
}

@Suite("Router")
struct RouterTests {
    // MARK: - Static routes

    @Test("Static route matches exact path")
    func staticMatch() throws {
        let builder = RouterBuilder()
        let registered = Box(false)
        builder.get("/health") { _ in
            registered.value = true
            return HTTPResponse.plaintext("ok")
        }

        let match = builder.build().match(method: .GET, path: "/health")
        #expect(match != nil)

        if let m = match {
            var ctx = RequestContext()
            ctx.params = m.params
            if case .sync(let fn) = m.handler { _ = try fn(ctx) }
            #expect(registered.value)
        }
    }

    @Test("Static route does not match different path")
    func staticMismatch() {
        let builder = RouterBuilder()
        builder.get("/health") { _ in HTTPResponse.plaintext("ok") }

        let match = builder.build().match(method: .GET, path: "/version")
        #expect(match == nil)
    }

    @Test("Root path matches empty pattern")
    func rootPath() {
        let builder = RouterBuilder()
        builder.get("/") { _ in HTTPResponse.plaintext("root") }

        let match = builder.build().match(method: .GET, path: "/")
        #expect(match != nil)
    }

    @Test("Trailing slash handled — `/health` matches `/health/`")
    func trailingSlash() {
        let builder = RouterBuilder()
        builder.get("/health") { _ in HTTPResponse.plaintext("ok") }

        // `/health/` splits into the same segments as `/health`.
        let match = builder.build().match(method: .GET, path: "/health/")
        #expect(match != nil)
    }

    // MARK: - Dynamic routes

    @Test("Dynamic segment captures value into params")
    func dynamicCapture() {
        let builder = RouterBuilder()
        builder.get("/users/:id") { _ in HTTPResponse.plaintext("user") }

        let match = builder.build().match(method: .GET, path: "/users/42")
        #expect(match != nil)
        #expect(match?.params["id"] == "42")
    }

    @Test("Multiple dynamic segments all captured")
    func multipleDynamic() {
        let builder = RouterBuilder()
        builder.get("/users/:userId/posts/:postId") { _ in
            HTTPResponse.plaintext("post")
        }

        let match = builder.build().match(method: .GET, path: "/users/7/posts/99")
        #expect(match != nil)
        #expect(match?.params["userId"] == "7")
        #expect(match?.params["postId"] == "99")
    }

    @Test("Dynamic segment requires non-empty capture")
    func dynamicEmptyRejected() {
        let builder = RouterBuilder()
        builder.get("/users/:id") { _ in HTTPResponse.plaintext("user") }

        // `/users/` splits into ["users"] — segment count mismatch.
        let match = builder.build().match(method: .GET, path: "/users/")
        #expect(match == nil)
    }

    // MARK: - Precedence: static beats dynamic

    @Test("Static route wins over dynamic when both match")
    func staticBeatsDynamic() throws {
        let builder = RouterBuilder()
        let hitDynamic = Box(false)
        let hitStatic = Box(false)
        // Register dynamic first to prove precedence is not "first
        // registered wins" — static must always win.
        builder.get("/users/me") { _ in
            hitStatic.value = true
            return HTTPResponse.plaintext("static")
        }
        builder.get("/users/:id") { _ in
            hitDynamic.value = true
            return HTTPResponse.plaintext("dynamic")
        }

        let match = builder.build().match(method: .GET, path: "/users/me")
        #expect(match != nil)
        if let m = match {
            var ctx = RequestContext()
            ctx.params = m.params
            if case .sync(let fn) = m.handler { _ = try fn(ctx) }
        }
        #expect(hitStatic.value)
        #expect(!hitDynamic.value)
    }

    @Test("Dynamic route still matches when static doesn't apply")
    func dynamicWhenNoStatic() throws {
        let builder = RouterBuilder()
        let hitDynamic = Box(false)
        builder.get("/users/me") { _ in HTTPResponse.plaintext("static") }
        builder.get("/users/:id") { _ in
            hitDynamic.value = true
            return HTTPResponse.plaintext("dynamic")
        }

        let match = builder.build().match(method: .GET, path: "/users/42")
        #expect(match != nil)
        #expect(match?.params["id"] == "42")
        if let m = match {
            var ctx = RequestContext()
            ctx.params = m.params
            if case .sync(let fn) = m.handler { _ = try fn(ctx) }
        }
        #expect(hitDynamic.value)
    }

    // MARK: - Method dispatch

    @Test("Method must match")
    func methodMismatch() {
        let builder = RouterBuilder()
        builder.get("/items") { _ in HTTPResponse.plaintext("list") }
        builder.post("/items") { _ in HTTPResponse.plaintext("create") }

        #expect(builder.build().match(method: .GET, path: "/items") != nil)
        #expect(builder.build().match(method: .POST, path: "/items") != nil)
        #expect(builder.build().match(method: .DELETE, path: "/items") == nil)
    }

    @Test("Same path different methods route to different handlers")
    func samePathDifferentMethods() throws {
        let builder = RouterBuilder()
        let hit = Box("")
        builder.get("/items") { _ in hit.value = "get"; return HTTPResponse.plaintext("g") }
        builder.post("/items") { _ in hit.value = "post"; return HTTPResponse.plaintext("p") }
        builder.delete("/items") { _ in hit.value = "delete"; return HTTPResponse.plaintext("d") }

        for (method, expected) in [(HTTPMethod.GET, "get"),
                                    (.POST, "post"),
                                    (.DELETE, "delete")] {
            guard let m = builder.build().match(method: method, path: "/items") else {
                Issue.record("No match for \(method)")
                continue
            }
            var ctx = RequestContext()
            if case .sync(let fn) = m.handler { _ = try fn(ctx) }
            #expect(hit.value == expected)
        }
    }

    // MARK: - Query string

    @Test("Query string stripped before matching")
    func queryStringStripped() {
        let builder = RouterBuilder()
        builder.get("/search") { _ in HTTPResponse.plaintext("results") }

        let match = builder.build().match(method: .GET, path: "/search?q=hello&page=2")
        #expect(match != nil)
    }

    @Test("Dynamic segment captured even with query string")
    func dynamicWithQuery() {
        let builder = RouterBuilder()
        builder.get("/users/:id") { _ in HTTPResponse.plaintext("u") }

        let match = builder.build().match(method: .GET, path: "/users/42?verbose=1")
        #expect(match != nil)
        #expect(match?.params["id"] == "42")
    }

    // MARK: - 404

    @Test("Unmatched path returns nil (caller emits 404)")
    func unmatchedReturnsNil() {
        let builder = RouterBuilder()
        builder.get("/here") { _ in HTTPResponse.plaintext("h") }

        #expect(builder.build().match(method: .GET, path: "/not-here") == nil)
        #expect(builder.build().match(method: .GET, path: "/here/sub") == nil)
    }

    @Test("Empty router returns nil for everything")
    func emptyRouter() {
        let builder = RouterBuilder()
        #expect(builder.build().match(method: .GET, path: "/") == nil)
        #expect(builder.build().match(method: .GET, path: "/anything") == nil)
    }

    // MARK: - Dispatch through match() + handler invocation
    //
    // Router.handle() was removed — the codec on the hot path calls
    // match() directly and synthesises its own 404. These tests now
    // drive the same path via the `dispatch()` helper at the top of
    // this file, which mirrors what the codec does: match → set
    // params → invoke handler.

    @Test("Unmatched path returns nil (404 is the codec's job)")
    func unmatchedReturnsNil() async throws {
        let builder = RouterBuilder()
        builder.get("/here") { _ in HTTPResponse.plaintext("h") }
        let response = try await dispatch(builder.build(), method: .GET, path: "/not-here")
        #expect(response == nil)
    }

    @Test("Matched handler receives params from the path")
    func handleInvokesMatched() async throws {
        let builder = RouterBuilder()
        let capturedParam = Box<String?>(nil)
        builder.get("/users/:id") { ctx in
            capturedParam.value = ctx.params["id"]
            return HTTPResponse.plaintext("ok")
        }
        _ = try await dispatch(builder.build(), method: .GET, path: "/users/123")
        #expect(capturedParam.value == "123")
    }

    @Test("Middleware wraps the matched handler")
    func middlewareWraps() async throws {
        let builder = RouterBuilder()
        let log = Box<[String]>([])
        builder.use(Middleware(
            before: { _ in log.value.append("before"); return .proceed },
            after: { _, r in log.value.append("after"); return r }
        ))
        builder.get("/x") { _ in
            log.value.append("handler")
            return HTTPResponse.plaintext("ok")
        }
        _ = try await dispatch(builder.build(), method: .GET, path: "/x")
        #expect(log.value == ["before", "handler", "after"])
    }

    @Test("Multiple middlewares compose outermost-first")
    func multipleMiddlewares() async throws {
        let builder = RouterBuilder()
        let log = Box<[String]>([])
        builder.use(Middleware(
            before: { _ in log.value.append("outer-before"); return .proceed },
            after: { _, r in log.value.append("outer-after"); return r }
        ))
        builder.use(Middleware(
            before: { _ in log.value.append("inner-before"); return .proceed },
            after: { _, r in log.value.append("inner-after"); return r }
        ))
        builder.get("/x") { _ in
            log.value.append("handler")
            return HTTPResponse.plaintext("ok")
        }
        _ = try await dispatch(builder.build(), method: .GET, path: "/x")
        #expect(log.value == [
            "outer-before", "inner-before", "handler",
            "inner-after", "outer-after"
        ])
    }

    @Test("Middleware applies to async handlers")
    func middlewareWrapsAsync() async throws {
        let builder = RouterBuilder()
        let log = Box<[String]>([])
        builder.use(Middleware(
            before: { _ in log.value.append("before"); return .proceed },
            after: { _, r in log.value.append("after"); return r }
        ))
        builder.get("/x") { _ async in
            log.value.append("handler")
            return HTTPResponse.plaintext("ok")
        }
        _ = try await dispatch(builder.build(), method: .GET, path: "/x")
        #expect(log.value == ["before", "handler", "after"])
    }

    @Test("Middleware shortCircuit skips handler")
    func middlewareShortCircuit() async throws {
        let builder = RouterBuilder()
        let handlerCalled = Box(false)
        builder.use(Middleware(
            before: { ctx in
                if ctx.pathString == "/blocked" {
                    return .shortCircuit(HTTPResponse.plaintext("denied"))
                }
                return .proceed
            }
        ))
        builder.get("/blocked") { _ in
            handlerCalled.value = true
            return HTTPResponse.plaintext("ok")
        }
        let response = try await dispatch(builder.build(), method: .GET, path: "/blocked")
        #expect(response != nil)
        #expect(!handlerCalled.value)
        let body = response!.headerBuffer.getString(at: 0, length: response!.headerBuffer.readableBytes)
        #expect(body?.contains("denied") == true)
    }

    @Test("Short-circuit in inner middleware still runs outer middleware's after")
    func shortCircuitOuterAfterRuns() async throws {
        let builder = RouterBuilder()
        let log = Box<[String]>([])
        // Outer middleware — its after MUST run even when inner short-circuits.
        builder.use(Middleware(
            before: { _ in log.value.append("outer-before"); return .proceed },
            after: { _, r in log.value.append("outer-after"); return r }
        ))
        // Inner middleware — short-circuits.
        builder.use(Middleware(
            before: { ctx in
                log.value.append("inner-before")
                return .shortCircuit(HTTPResponse.plaintext("blocked"))
            },
            after: { _, r in log.value.append("inner-after"); return r }
        ))
        builder.get("/x") { _ in
            log.value.append("handler")
            return HTTPResponse.plaintext("ok")
        }
        _ = try await dispatch(builder.build(), method: .GET, path: "/x")
        // outer-before → inner-before → inner-after → outer-after
        // Handler is skipped. Both after hooks run.
        #expect(log.value == [
            "outer-before", "inner-before",
            "inner-after", "outer-after"
        ])
    }

    // MARK: - Pattern parsing edge cases

    @Test("Pattern with multiple consecutive slashes normalizes")
    func patternConsecutiveSlashes() {
        // The router splits on '/' and skips empty segments, so a
        // pattern like `//users//42` should match `/users/42`.
        let builder = RouterBuilder()
        builder.get("/users/:id") { _ in HTTPResponse.plaintext("u") }

        #expect(builder.build().match(method: .GET, path: "//users//42") != nil)
    }

    // MARK: - Route registration count

    @Test("routeCount reflects registered routes")
    func routeCount() {
        let builder = RouterBuilder()
        #expect(builder.build().routeCount == 0)
        builder.get("/a") { _ in HTTPResponse.plaintext("a") }
        builder.get("/b") { _ in HTTPResponse.plaintext("b") }
        builder.post("/c") { _ in HTTPResponse.plaintext("c") }
        #expect(builder.build().routeCount == 3)
    }
}
