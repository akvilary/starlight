//===----------------------------------------------------------------------===//
//
//  Router.swift
//  StarlightRouting
//
//  HTTP request router. Matches incoming (method, path) against
//  registered patterns and dispatches to the user handler, populating
//  `ctx.params` with dynamic-segment values.
//
//  ─── MVP: linear search with segment-wise comparison ───────────────────
//
//  Phase 3 ships a simple O(routes × segments) matcher. This is fine
//  up to ~100 routes — typical application routers see ~10-50 routes
//  in the hot path. Phase 4 will replace this with a radix trie
//  (matchit-style) that reduces matching to O(path length) with no
//  backtracking.
//
//  ─── Pattern syntax ────────────────────────────────────────────────────
//
//    `/users/42`            → static match
//    `/users/:id`           → capture `42` into params["id"]
//    `/files/:path/*`       → catch-all (Phase 4)
//
//  Static segments take priority over dynamic ones during matching —
//  if both `/users/me` and `/users/:id` are registered, a request to
//  `/users/me` matches the static route. This mirrors axum/matchit
//  precedence.
//
//===----------------------------------------------------------------------===//

import NIOCore
import Synchronization
import StarlightHTTP

/// A single path segment of a route pattern.
@usableFromInline
enum RouteSegment: Equatable, Sendable {
    /// Static text — must match exactly. Pre-compiled UTF-8 bytes
    /// for zero-index byte comparison during matching.
    case literal([UInt8])
    /// Named capture — matches any non-empty segment, captures into params[name].
    case param(String)
}

/// A registered route.
struct Route: Sendable {
    let method: HTTPMethod
    /// Original pattern, kept for diagnostics / `debugPrint`.
    let pattern: String
    /// Pre-split segments for fast matching.
    let segments: [RouteSegment]
    /// Sync or async dispatch kind. `var` so `freeze()` can replace
    /// it with the middleware-composed version once at startup.
    var handler: HandlerKind
}

/// Result of a middleware's `before` hook: proceed to the handler,
/// or short-circuit by returning a response immediately.
public enum MiddlewareResult: Sendable {
    /// Continue to the next middleware / handler in the chain.
    case proceed
    /// Skip the handler and all remaining middleware. The supplied
    /// response is returned to the client (after running this
    /// middleware's `after` hook and all outer middleware's `after`
    /// hooks).
    case shortCircuit(HTTPResponse)
}

/// HTTP middleware — composable before/after hooks around route handlers.
///
/// A middleware has two hooks:
/// - `before`: inspects the request. Return `.shortCircuit` to reject
///   early (auth, rate-limit) or `.proceed` to continue.
/// - `after`: inspects/modifies the response (CORS headers, logging,
///   compression).
///
/// Both hooks are **sync** closures. This covers virtually all middleware
/// use cases (auth header checks, CORS, logging, rate-limiting). When a
/// middleware needs async work (database lookup, upstream call), use the
/// `init(sync:async:)` or `init(_:)` initialiser to provide a full
/// async wrapper.
///
/// **Sync fast-path**: when *every* middleware in the chain is created
/// via `init(before:after:)` or `init(sync:async:)`, sync routes stay
/// fully sync — zero async overhead. When any middleware is async-only
/// (`init(_:)`), sync routes are promoted to async (minimal overhead
/// with `NonisolatedNonsendingByDefault` — no Task allocation, no
/// executor hop).
public struct Middleware: Sendable {
    // MARK: - Composition closures

    /// Compose this middleware around a sync handler. `nil` when the
    /// middleware is async-only.
    public let wrapSync: (@Sendable (@escaping HTTPHandler) -> HTTPHandler)?

    /// Compose this middleware around an async handler. Always present —
    /// guarantees middleware works for async routes.
    public let wrapAsync: @Sendable (@escaping AsyncHTTPHandler) -> AsyncHTTPHandler

    // MARK: - Initialisers

    /// Before/after hook middleware. The simplest and most common form —
    /// covers auth, CORS, logging, rate-limiting.
    ///
    /// Both hooks are sync. This generates both `wrapSync` and
    /// `wrapAsync` automatically, so sync routes with this middleware
    /// stay fully sync.
    public init(
        before: @escaping @Sendable (borrowing RequestContext) -> MiddlewareResult = { _ in .proceed },
        after: @escaping @Sendable (borrowing RequestContext, HTTPResponse) -> HTTPResponse = { _, r in r }
    ) {
        self.wrapSync = { next in
            return { ctx in
                switch before(ctx) {
                case .proceed:
                    return after(ctx, next(ctx))
                case .shortCircuit(let response):
                    return after(ctx, response)
                }
            }
        }
        self.wrapAsync = { next in
            return { ctx async in
                switch before(ctx) {
                case .proceed:
                    return after(ctx, await next(ctx))
                case .shortCircuit(let response):
                    return after(ctx, response)
                }
            }
        }
    }

    /// Async-only middleware. Sync routes in the chain will be promoted
    /// to async. Use when the middleware needs `await` (database auth,
    /// upstream HTTP calls).
    public init(_ wrapAsync: @escaping @Sendable (@escaping AsyncHTTPHandler) -> AsyncHTTPHandler) {
        self.wrapAsync = wrapAsync
        self.wrapSync = nil
    }

    /// Full-control middleware: explicit sync and async wrappers.
    /// The sync wrapper keeps sync routes zero-overhead; the async
    /// wrapper covers async routes.
    public init(
        sync wrapSync: @escaping @Sendable (@escaping HTTPHandler) -> HTTPHandler,
        async wrapAsync: @escaping @Sendable (@escaping AsyncHTTPHandler) -> AsyncHTTPHandler
    ) {
        self.wrapSync = wrapSync
        self.wrapAsync = wrapAsync
    }
}

/// HTTP request router.
///
/// Routes are stored in registration order. Static-segment routes are
/// tried before dynamic-segment routes when both can match — this is
/// implemented by partitioning routes at registration time so the
/// search still terminates as soon as a match is found.
///
/// **Lifecycle invariant**: routes and middleware must be registered
/// *before* the router is attached to a server (i.e. before
/// `StarlightServer.start(... router: router ...)` is called). The
/// router is not thread-safe for concurrent reads and writes — it
/// assumes registration happens on a single thread during startup,
/// and only `handle(_:)` is invoked concurrently from event loops.
/// Debug builds assert this invariant; release builds trust the caller.
public final class Router: @unchecked Sendable {
    /// User handlers indexed by route. Searched linearly.
    private var routes: [Route] = []

    /// Static-only routes (all segments are `.literal`), tried first
    /// so static precedence is guaranteed without per-request
    /// `allSatisfy` overhead.
    private var staticRoutes: [Route] = []

    /// Routes containing at least one `.param` segment, tried after
    /// the static partition.
    private var dynamicRoutes: [Route] = []

    /// Middleware chain applied around every handler. The chain is
    /// pre-composed at `makeHandler()` time so per-request dispatch is
    /// just "call the matched handler" — middleware wrapping is
    /// folded into the handler closure.
    private var middlewares: [Middleware] = []

    /// Atomically tracks whether `freeze()` has been called.
    /// `compareExchange` in `freeze()` ensures only one thread
    /// performs middleware composition.
    private let isFrozen = Atomic<Bool>(false)

    public init() {}

    // MARK: - Registration (sync)

    /// Register a **sync** handler for `GET <pattern>`.
    public func get(_ pattern: String, _ handler: @escaping HTTPHandler) {
        self.add(.GET, pattern, .sync(handler))
    }
    public func post(_ pattern: String, _ handler: @escaping HTTPHandler) {
        self.add(.POST, pattern, .sync(handler))
    }
    public func put(_ pattern: String, _ handler: @escaping HTTPHandler) {
        self.add(.PUT, pattern, .sync(handler))
    }
    public func patch(_ pattern: String, _ handler: @escaping HTTPHandler) {
        self.add(.PATCH, pattern, .sync(handler))
    }
    public func delete(_ pattern: String, _ handler: @escaping HTTPHandler) {
        self.add(.DELETE, pattern, .sync(handler))
    }
    public func head(_ pattern: String, _ handler: @escaping HTTPHandler) {
        self.add(.HEAD, pattern, .sync(handler))
    }
    public func options(_ pattern: String, _ handler: @escaping HTTPHandler) {
        self.add(.OPTIONS, pattern, .sync(handler))
    }

    // MARK: - Registration (async)

    /// Register an **async** handler for `GET <pattern>`. Runs inline
    /// in the connection Task via `await` — zero Task-per-request
    /// allocation.
    public func get(_ pattern: String, async handler: @escaping AsyncHTTPHandler) {
        self.add(.GET, pattern, .async(handler))
    }
    public func post(_ pattern: String, async handler: @escaping AsyncHTTPHandler) {
        self.add(.POST, pattern, .async(handler))
    }
    public func put(_ pattern: String, async handler: @escaping AsyncHTTPHandler) {
        self.add(.PUT, pattern, .async(handler))
    }
    public func patch(_ pattern: String, async handler: @escaping AsyncHTTPHandler) {
        self.add(.PATCH, pattern, .async(handler))
    }
    public func delete(_ pattern: String, async handler: @escaping AsyncHTTPHandler) {
        self.add(.DELETE, pattern, .async(handler))
    }

    /// Register a handler for an arbitrary method + pattern.
    public func add(_ method: HTTPMethod, _ pattern: String, _ kind: HandlerKind) {
        precondition(!isFrozen.load(ordering: .acquiring),
            "Router.add called after the router has been attached to a server. " +
            "Register all routes before calling StarlightServer.start(...).")
        if case .other = method {
            preconditionFailure("Cannot register a route for .other — it would match every unknown method.")
        }
        let segments = Self.parsePattern(pattern)
        let route = Route(method: method, pattern: pattern, segments: segments, handler: kind)
        let isAllStatic = segments.allSatisfy {
            if case .literal = $0 { return true } else { return false }
        }
        if isAllStatic {
            staticRoutes.append(route)
        } else {
            dynamicRoutes.append(route)
        }
        routes.append(route)
    }

    /// Append a middleware to the chain. Middlewares are invoked in
    /// registration order, outermost-first.
    ///
    /// - Precondition: must be called before the router is attached
    ///   to a server. Debug builds trap if called after the first
    ///   `handle(_:)` invocation.
    public func use(_ middleware: Middleware) {
        precondition(!isFrozen.load(ordering: .acquiring),
            "Router.use called after the router has been attached to a server. " +
            "Register all middleware before calling StarlightServer.start(...).")
        self.middlewares.append(middleware)
    }

    // MARK: - Dispatch

    /// Pre-compose middleware into each route's handler. Called once
    /// from `StarlightServer.start()` before any connection is
    /// accepted. Thread-safe via `Atomic<Bool>` compareExchange —
    /// if multiple event loops call this concurrently, only one
    /// performs the composition.
    public func freeze() {
        let (exchanged, _) = isFrozen.compareExchange(
            expected: false, desired: true, ordering: .acquiringAndReleasing
        )
        guard exchanged else { return }
        guard !middlewares.isEmpty else { return }
        for i in staticRoutes.indices {
            staticRoutes[i].handler = composeOne(staticRoutes[i].handler)
        }
        for i in dynamicRoutes.indices {
            dynamicRoutes[i].handler = composeOne(dynamicRoutes[i].handler)
        }
    }

    /// Compose middleware chain around a single handler. Called only
    /// from `freeze()`, never per-request.
    ///
    /// Composition rules:
    /// - **Sync handler + all-middleware-have-wrapSync**: stays sync.
    ///   Zero async overhead — the fast path for typical apps.
    /// - **Sync handler + any-middleware-async-only**: promoted to async.
    ///   Overhead is one continuation hop (no Task allocation, no
    ///   executor hop under `NonisolatedNonsendingByDefault`).
    /// - **Async handler**: always composes via `wrapAsync`. Middleware
    ///   is fully applied (the bug that silently skipped middleware
    ///   for async routes is fixed).
    private func composeOne(_ handler: HandlerKind) -> HandlerKind {
        switch handler {
        case .sync(let fn):
            if middlewares.allSatisfy({ $0.wrapSync != nil }) {
                var h: HTTPHandler = fn
                for mw in self.middlewares.reversed() {
                    h = mw.wrapSync!(h)
                }
                return .sync(h)
            }
            var h: AsyncHTTPHandler = { ctx async in fn(ctx) }
            for mw in self.middlewares.reversed() {
                h = mw.wrapAsync(h)
            }
            return .async(h)

        case .async(let fn):
            var h: AsyncHTTPHandler = fn
            for mw in self.middlewares.reversed() {
                h = mw.wrapAsync(h)
            }
            return .async(h)
        }
    }

    /// Dispatch a parsed request through the router.
    ///
    /// This is the entry point that `HTTP1Codec` calls once the
    /// request line + headers have been parsed. The router:
    ///   1. Matches `(ctx.method, ctx.path)` against the routes.
    ///   2. Populates `ctx.params` with any dynamic-segment captures.
    ///   3. Invokes the matched handler (sync or async).
    ///   4. Returns a 404 response if no route matched.
    ///
    /// Middleware is pre-composed at `freeze()` time — per-request
    /// dispatch is just "call the matched handler."
    public func handle(_ ctx: inout RequestContext) async -> HTTPResponse {
        // freeze() is idempotent. In production, Server.start() calls
        // it before any connection is accepted, so this is a no-op.
        // In tests (where start() isn't called), this ensures
        // middleware is composed on first use — single-threaded, no
        // race.
        freeze()
        let method = ctx.method
        guard let match = match(method: method, path: ctx.path) else {
            return HTTPResponse.plaintext(
                "404 Not Found: \(method) \(ctx.pathString)\n",
                status: HTTPStatus(404, reasonPhrase: "Not Found"),
                keepAlive: false,
                into: &ctx.responseBuffer
            )
        }
        ctx.params = match.params

        switch match.handler {
        case .sync(let fn):
            return fn(ctx)
        case .async(let fn):
            return await fn(ctx)
        }
    }

    // MARK: - Internal matching

    /// Match `(method, path)` against the registered routes and return
    /// the matching handler + extracted params. Returns `nil` if no
    /// route matched.
    ///
    /// Accepts a `ByteBuffer` (COW slice of the accumulator) instead of
    /// a `String` — avoids the heap allocation that `String(decoding:)`
    /// incurs for paths > 15 bytes. Uses `withUnsafeReadableBytes` to
    /// get a contiguous byte view and walks the pre-compiled route
    /// segments in-place — zero array allocation, zero String
    /// allocation (except for param values, which use SmallString for
    /// ≤ 15 bytes).
    public func match(method: HTTPMethod, path: ByteBuffer) -> (handler: HandlerKind, params: Params)? {
        path.withUnsafeReadableBytes { rawBytes -> (handler: HandlerKind, params: Params)? in
            guard let base = rawBytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return nil
            }
            let total = rawBytes.count
            // Strip query string.
            var pathLen = total
            for i in 0..<total {
                if base[i] == 0x3F { pathLen = i; break }
            }
            // Reuse a single Params across all candidates — avoids
            // per-candidate array allocation. removeAll(keepingCapacity:)
            // preserves the backing array for reuse.
            var params = Params()
            // Static routes first (pre-partitioned at registration).
            for route in staticRoutes where route.method == method {
                params.removeAll()
                if Self.matchBytes(route.segments, base, pathLen, &params) {
                    params.setBackingBuffer(path)
                    return (route.handler, params)
                }
            }
            // Dynamic routes.
            for route in dynamicRoutes where route.method == method {
                params.removeAll()
                if Self.matchBytes(route.segments, base, pathLen, &params) {
                    params.setBackingBuffer(path)
                    return (route.handler, params)
                }
            }
            return nil
        }
    }

    /// Convenience overload that accepts a `String` path. Allocates
    /// a temporary `ByteBuffer` — use the `ByteBuffer` overload for
    /// the hot path (zero-copy from the accumulator).
    public func match(method: HTTPMethod, path: String) -> (handler: HandlerKind, params: Params)? {
        var buf = ByteBufferAllocator().buffer(capacity: path.utf8.count)
        buf.writeString(path)
        return self.match(method: method, path: buf)
    }

    /// Walk raw path bytes against pre-compiled route segments.
    /// Returns `true` if the route matches, populating `params` with
    /// captured values. Uses integer-indexed pointer arithmetic — no
    /// String.UTF8View opaque-index overhead, no array allocation.
    @usableFromInline
    @inline(__always)
    static func matchBytes(
        _ segments: [RouteSegment],
        _ path: UnsafePointer<UInt8>,
        _ pathLen: Int,
        _ params: inout Params
    ) -> Bool {
        var pos = 0
        for segment in segments {
            // Skip leading '/' separators (handles consecutive slashes).
            while pos < pathLen && path[pos] == 0x2F { pos += 1 }
            switch segment {
            case .literal(let bytes):
                guard pos + bytes.count <= pathLen else { return false }
                for i in 0..<bytes.count {
                    if path[pos] != bytes[i] { return false }
                    pos += 1
                }
            case .param(let name):
                // Capture until next '/' or end of (query-stripped) path.
                let start = pos
                while pos < pathLen && path[pos] != 0x2F {
                    pos += 1
                }
                if pos == start { return false }
                // Record the byte range — no String allocation during
                // matching. The value is materialised on-demand via
                // subscript when (and if) the handler reads it.
                params.appendParam(name: name, offset: start, length: pos - start)
            }
        }
        // Entire path (up to query string) must be consumed.
        // Tolerate a single trailing '/'.
        return pos == pathLen
            || (pos + 1 == pathLen && path[pos] == 0x2F)
    }

    // MARK: - Pattern / path parsing

    /// Split a URL path into non-empty segments.
    static func splitPath(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    /// Parse a route pattern (e.g. `/users/:id`) into segments with
    /// pre-compiled bytes for zero-allocation matching.
    static func parsePattern(_ pattern: String) -> [RouteSegment] {
        let parts = splitPath(pattern)
        return parts.map { part in
            if part.hasPrefix(":") {
                return .param(String(part.dropFirst()))
            } else {
                let s = String(part)
                return .literal(Array(s.utf8))
            }
        }
    }

    /// Number of registered routes. Useful for tests.
    public var routeCount: Int { self.routes.count }
}
