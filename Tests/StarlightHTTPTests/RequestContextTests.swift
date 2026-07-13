//===----------------------------------------------------------------------===//
//
//  RequestContextTests.swift
//  StarlightHTTPTests
//
//  Verifies the per-request context behaves correctly across
//  keep-alive reset cycles.
//
//===----------------------------------------------------------------------===//

import Testing
@testable import StarlightHTTP

@Suite("RequestContext")
struct RequestContextTests {
    // MARK: - Defaults

    @Test("Default init has safe defaults")
    func defaultInit() {
        var ctx = RequestContext()
        #expect(ctx.method.isOther)
        #expect(ctx.status == .ok)
        #expect(ctx.headers.isEmpty)
        #expect(ctx.body == nil)
    }

    // MARK: - Reset

    @Test("reset() restores defaults")
    func resetRestoresDefaults() {
        var ctx = RequestContext()
        ctx.method = .GET
        ctx.status = .notFound

        ctx.reset()

        #expect(ctx.method.isOther)
        #expect(ctx.status == .ok)
        #expect(ctx.body == nil)
    }

    @Test("reset() enables hundreds of request cycles")
    func manyRequestCycles() {
        var ctx = RequestContext()
        for _ in 0..<100 {
            ctx.method = .GET
            ctx.status = .notFound
            ctx.reset()
        }
        #expect(ctx.method.isOther)
        #expect(ctx.status == .ok)
    }

    // MARK: - Status mutation

    @Test("Handler can set custom status")
    func handlerSetsStatus() {
        var ctx = RequestContext()
        ctx.status = HTTPStatus(503, reasonPhrase: "Service Unavailable")
        #expect(ctx.status.code == 503)
        #expect(ctx.status.reasonPhrase == "Service Unavailable")
    }

    // MARK: - Method mutation

    @Test("Handler can read method set by parser")
    func handlerReadsMethod() {
        var ctx = RequestContext()
        ctx.method = .POST
        #expect(ctx.method == .POST)
    }

    // MARK: - Path

    @Test("setPath and pathString round-trip")
    func pathRoundTrip() {
        var ctx = RequestContext()
        ctx.setPath("/users/42")
        #expect(ctx.pathString == "/users/42")
    }

    @Test("reset() clears path")
    func resetClearsPath() {
        var ctx = RequestContext()
        ctx.setPath("/api/v1")
        ctx.reset()
        #expect(ctx.pathString == "")
    }
}
