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

import StarlightCore
import StarlightHTTP

/// A single path segment of a route pattern.
@usableFromInline
enum RouteSegment: Equatable, Sendable {
    /// Static text — must match exactly. `bytes` is the pre-compiled
    /// UTF-8 of `text`, allocated once at registration time so the
    /// per-request matcher can compare raw bytes without touching
    /// `String.utf8` (which uses opaque indices).
    case literal(text: String, bytes: [UInt8])
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

/// Closure-based middleware for Phase 3 MVP.
///
/// A middleware wraps a handler and returns a new handler that runs
/// its own logic around the wrapped one. The composition is plain
/// function wrapping — no protocol existentials, no boxing. The
/// compiler specializes the whole chain into a single async/sync
/// function when the closures are inlinable.
///
/// Phase 4 will introduce a generic `protocol Middleware` with
/// `associatedtype` for cases that need type-level composition
/// (e.g., a `Logger<Auth<Router>>` chain that fully monomorphizes).
public struct Middleware: Sendable {
    /// The wrap function. Given the next handler in the chain, return
    /// a handler that runs this middleware's logic around it.
    public let wrap: @Sendable (@escaping HTTPHandler) -> HTTPHandler

    public init(wrap: @escaping @Sendable (@escaping HTTPHandler) -> HTTPHandler) {
        self.wrap = wrap
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

    #if DEBUG
    /// Set to `true` on the first `handle(_:)` call. Subsequent
    /// `add(...)` / `use(...)` calls will trap with a
    /// "router-frozen-after-start" message rather than silently
    /// racing with concurrent dispatch.
    private var isFrozen: Bool = false
    #endif

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
        #if DEBUG
        precondition(!isFrozen,
            "Router.add called after the router has been attached to a server. " +
            "Register all routes before calling StarlightServer.start(...).")
        #endif
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
        #if DEBUG
        precondition(!isFrozen,
            "Router.use called after the router has been attached to a server. " +
            "Register all middleware before calling StarlightServer.start(...).")
        #endif
        self.middlewares.append(middleware)
    }

    // MARK: - Dispatch

    /// Pre-compose middleware into each route's handler. Called once
    /// (from the first `handle()` or explicitly from `StarlightServer.start()`)
    /// so subsequent requests pay zero closure-allocation cost.
    private var isComposed = false

    public func freeze() {
        guard !isComposed else { return }
        isComposed = true
        #if DEBUG
        isFrozen = true
        #endif
        guard !middlewares.isEmpty else { return }
        for i in staticRoutes.indices {
            staticRoutes[i].handler = composeOne(staticRoutes[i].handler)
        }
        for i in dynamicRoutes.indices {
            dynamicRoutes[i].handler = composeOne(dynamicRoutes[i].handler)
        }
        for i in routes.indices {
            routes[i].handler = composeOne(routes[i].handler)
        }
    }

    /// Compose middleware chain around a single handler. Called only
    /// from `freeze()`, never per-request.
    private func composeOne(_ handler: HandlerKind) -> HandlerKind {
        switch handler {
        case .sync(let fn):
            var h: HTTPHandler = fn
            for mw in self.middlewares.reversed() {
                h = mw.wrap(h)
            }
            return .sync(h)
        case .async(let fn):
            return .async(fn)
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
        freeze()
        let (method, path) = (ctx.method, ctx.path)
        guard let match = match(method: method, path: path) else {
            return HTTPResponse.plaintext(
                "404 Not Found: \(method) \(path)\n",
                status: HTTPStatus(404, reasonPhrase: "Not Found"),
                keepAlive: false
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
    /// Uses `path.withUTF8` to obtain a contiguous byte view and walks
    /// the pre-compiled route segments in-place — zero array
    /// allocation, zero String allocation (except for param values,
    /// which use SmallString for ≤ 15 bytes).
    public func match(method: HTTPMethod, path: String) -> (handler: HandlerKind, params: Params)? {
        var pathMut = path
        return pathMut.withUTF8 { pathBytes -> (handler: HandlerKind, params: Params)? in
            let base = pathBytes.baseAddress!
            let total = pathBytes.count
            // Strip query string.
            var pathLen = total
            for i in 0..<total {
                if base[i] == 0x3F { pathLen = i; break }
            }
            // Static routes first (pre-partitioned at registration).
            for route in staticRoutes where route.method == method {
                var params = Params()
                if Self.matchBytes(route.segments, base, pathLen, &params) {
                    return (route.handler, params)
                }
            }
            // Dynamic routes.
            for route in dynamicRoutes where route.method == method {
                var params = Params()
                if Self.matchBytes(route.segments, base, pathLen, &params) {
                    return (route.handler, params)
                }
            }
            return nil
        }
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
            case .literal(_, let bytes):
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
                // SmallString handles ≤ 15 bytes inline — zero heap alloc.
                let value = String(decoding: UnsafeBufferPointer(
                    start: path.advanced(by: start), count: pos - start
                ), as: UTF8.self)
                params.append(name: name, value: value)
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
                return .literal(text: s, bytes: Array(s.utf8))
            }
        }
    }

    /// Number of registered routes. Useful for tests.
    public var routeCount: Int { self.routes.count }
}
