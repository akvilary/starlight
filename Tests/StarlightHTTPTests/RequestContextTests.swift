//===----------------------------------------------------------------------===//
//
//  RequestContextTests.swift
//  StarlightHTTPTests
//
//  Verifies the per-request context behaves as a bump-arena-backed,
//  zero-copy reset target.
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
        #expect(ctx.method == .other)
        #expect(ctx.status == .ok)
        #expect(ctx.arenaUsedBytes == 0)
        #expect(ctx.arenaReservedBytes == 0)  // arena is lazy
    }

    @Test("Custom initial arena size is honoured")
    func customArenaSize() {
        var ctx = RequestContext(initialArenaSize: 8 * 1024)
        _ = ctx.allocate(bytes: 100, alignment: 1)
        #expect(ctx.arenaReservedBytes == 8 * 1024)
    }

    // MARK: - Allocation

    @Test("allocate(bytes:alignment:) bumps arena usage")
    func allocateFromArena() {
        var ctx = RequestContext(initialArenaSize: 256)
        let buf = ctx.allocate(bytes: 64, alignment: 1)
        #expect(buf.count == 64)
        #expect(buf.baseAddress != nil)
        #expect(ctx.arenaUsedBytes == 64)
    }

    @Test("allocate(value) initializes typed memory")
    func allocateTyped() {
        struct User { let id: Int; let name: String }
        var ctx = RequestContext(initialArenaSize: 256)
        let ptr = ctx.allocate(User(id: 42, name: "ada"))
        #expect(ptr.pointee.id == 42)
        #expect(ptr.pointee.name == "ada")
    }

    // MARK: - Reset

    @Test("reset() zeroes arena usage and restores defaults")
    func resetZeroesAndRestores() {
        var ctx = RequestContext(initialArenaSize: 256)
        ctx.method = .GET
        ctx.status = .notFound
        _ = ctx.allocate(bytes: 200, alignment: 1)
        #expect(ctx.arenaUsedBytes == 200)

        ctx.reset()

        #expect(ctx.method == .other)
        #expect(ctx.status == .ok)
        #expect(ctx.arenaUsedBytes == 0)
        // Chunks are kept for reuse — no malloc on next cycle.
        #expect(ctx.arenaReservedBytes == 256)
    }

    @Test("reset() enables hundreds of request cycles without new malloc")
    func manyRequestCycles() {
        // Simulate 100 keep-alive requests on one connection.
        var ctx = RequestContext(initialArenaSize: 1024)
        for _ in 0..<100 {
            // Each "request" allocates 500 bytes of scratch.
            _ = ctx.allocate(bytes: 500, alignment: 1)
            ctx.reset()
        }
        // After 100 cycles, chunks should still be the same one — no
        // growth, no leaks.
        #expect(ctx.arenaReservedBytes == 1024)
        #expect(ctx.arenaUsedBytes == 0)
    }

    // MARK: - releaseAll

    @Test("releaseAll() empties the arena")
    func releaseAllEmptiesArena() {
        var ctx = RequestContext(initialArenaSize: 256)
        _ = ctx.allocate(bytes: 100, alignment: 1)
        ctx.releaseAll()
        #expect(ctx.arenaReservedBytes == 0)
        #expect(ctx.arenaUsedBytes == 0)
        // Context is still usable — fresh allocation will create a new chunk.
        _ = ctx.allocate(bytes: 50, alignment: 1)
        #expect(ctx.arenaReservedBytes == 256)
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
}
