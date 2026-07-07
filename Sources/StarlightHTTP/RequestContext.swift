//===----------------------------------------------------------------------===//
//
//  RequestContext.swift
//  StarlightHTTP
//
//  Per-request state, modelled on fasthttp's `RequestCtx` but with the
//  reuse-invariant enforced at compile time by Swift's ownership model.
//
//  ─── Why `~Copyable` ───────────────────────────────────────────────────
//
//  fasthttp reuses a single `RequestCtx` per connection across all
//  keep-alive requests and warns the user "do not retain `RequestCtx`
//  references after the handler returns" — a runtime hazard that Go's
//  type system cannot enforce. Swift's `~Copyable` lets us encode the
//  same invariant statically:
//
//    - The context is owned by exactly one task (the connection's task).
//    - It is passed to handlers as `borrowing RequestContext` — the
//      handler cannot escape it, cannot store it, cannot keep it alive
//      past its scope.
//    - Between requests the owner calls `reset()`, which bulk-frees the
//      arena and zeros the parsed fields in one O(1) pass.
//
//  This is exactly the safety-vs-speed trade fasthttp cannot give us.
//
//  ─── Why not `~Escapable` (yet) ────────────────────────────────────────
//
//  `~Escapable` would let us tie the context's lifetime to the
//  connection's receive buffer via Swift's experimental lifetime-
//  dependencies feature, which would prevent even borrowed views into
//  the context from escaping (think: a captured `Span<UInt8>` view of
//  the path that outlives the request). We will adopt `~Escapable` in
//  a later phase once the lifetime-dependencies feature is no longer
//  experimental; for now `~Copyable` + `borrowing` is the right shape.
//
//===----------------------------------------------------------------------===//

import StarlightCore

/// Per-request state owned by a single connection's task.
///
/// One instance per connection, reused across all keep-alive requests.
/// The owner resets the context between requests via `reset()`.
///
/// Handlers receive the context as `borrowing RequestContext` — they
/// cannot copy it, store it, or extend its lifetime past the handler
/// call. This is the compile-time-enforced equivalent of fasthttp's
/// runtime-only "don't keep references" invariant.
public struct RequestContext: ~Copyable {
    /// Per-request bump allocator. All request-scoped allocations
    /// (header copies, parsed path, etc.) come from here. Bulk-freed by
    /// `reset()`.
    @usableFromInline var arena: ArenaAllocator

    /// HTTP method. Populated by the SIMD parser in Phase 2.
    public var method: HTTPMethod

    /// HTTP status code that the handler will emit. Defaults to 200 OK;
    /// handlers can mutate it (e.g., set to 404 for not-found). The
    /// response writer in Phase 2 reads this when serializing the
    /// status line.
    public var status: HTTPStatus

    /// Request path (e.g. `/users/42`). Allocated in the arena during
    /// request-line parsing. Reset by `reset()`.
    public var path: String

    /// Path parameters extracted by the router from dynamic segments
    /// (e.g. `:id` in `/users/:id` → `params["id"] == "42"`).
    ///
    /// Backed by `Params` (array of `(name, value)` tuples) rather
    /// than a `Dictionary` — for typical 0–2-param routes this is
    /// cheaper to allocate and faster to look up.
    public var params: Params

    /// Captured request headers. Populated by the HTTP/1 parser after
    /// the entire header block has been parsed.
    public var headers: HeaderView

    /// Request body bytes (for POST/PUT/PATCH). Copied into the arena
    /// during body parsing. Nil for bodyless requests (GET/HEAD/etc.).
    public var body: [UInt8]?

    // ── Phase 3 will add: ───────────────────────────────────────────────
    //   - headers: HeaderView         (case-insensitive ordered storage)
    //   - body: Span<UInt8>          (zero-copy for in-buffer bodies,
    //                                  arena-backed for streamed bodies)

    /// Construct an empty context with a fresh arena.
    ///
    /// - Parameter initialArenaSize: starting chunk size for the arena.
    ///   Default 4 KiB — fits typical HTTP/1.1 request headers + URL on
    ///   one page.
    public init(initialArenaSize: Int = 4 * 1024) {
        self.arena = ArenaAllocator(initialChunkSize: initialArenaSize)
        self.method = .other
        self.status = .ok
        self.path = ""
        self.params = Params()
        self.headers = HeaderView()
        self.body = nil
    }

    /// Reset the context between keep-alive requests on the same connection.
    ///
    /// Bulk-frees the arena (no `malloc` for the next request's
    /// allocations as long as they fit in the existing chunks) and
    /// restores `method`, `status`, `path`, `params` to their defaults.
    ///
    /// - Complexity: O(chunks). Independent of the number of allocations
    ///   made by the previous request.
    public mutating func reset() {
        self.arena.reset()
        self.method = .other
        self.status = .ok
        self.path = ""
        // params is replaced wholesale on the next request — clearing
        // it costs O(n) in the number of params from the previous
        // request. We could leave it dirty and overwrite, but the
        // arena-reset frees the underlying string storage anyway.
        self.params.removeAll()
        self.headers.removeAll()
        self.body = nil
    }

    /// Release all arena memory back to the system allocator. Use this
    /// when a connection is closing and the context will not be reused.
    public mutating func releaseAll() {
        self.arena.releaseAll()
    }

    /// Allocate `bytes` from the per-request arena. Memory is valid
    /// until the next `reset()` or `releaseAll()`.
    ///
    /// This is the primary allocation path for handler scratch space
    /// (JSON building, response body construction, etc.). It avoids
    /// per-allocation ARC traffic and bulk-frees with the request.
    @inlinable
    public mutating func allocate(
        bytes: Int,
        alignment: Int = MemoryLayout<Int>.alignment
    ) -> UnsafeMutableRawBufferPointer {
        self.arena.allocate(bytes: bytes, alignment: alignment)
    }

    /// Allocate and initialize a single `T` in the arena.
    @inlinable
    public mutating func allocate<T>(_ value: T) -> UnsafeMutablePointer<T> {
        self.arena.allocate(value)
    }

    /// Bytes reserved by arena chunks across the connection's lifetime.
    /// Useful for stats.
    @inlinable
    public var arenaReservedBytes: Int { self.arena.reservedBytes }

    /// Bytes currently in use by the arena.
    @inlinable
    public var arenaUsedBytes: Int { self.arena.usedBytes }
}
