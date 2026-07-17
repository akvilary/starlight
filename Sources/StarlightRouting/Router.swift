//===----------------------------------------------------------------------===//
//
//  Router.swift
//  StarlightRouting
//
//  HTTP request router. Two-type design (type-state pattern):
//
//    ┌─────────────────────────────┐         ┌─────────────────────┐
//    │  RouterBuilder              │  build  │  Router             │
//    │  (class, mutable, !Sendable)│ ──────► │  (struct, immutable │
//    │                             │         │   Sendable)         │
//    │  get/post/put/...           │         │                     │
//    │  use(middleware)            │         │  match(...)         │
//    │  add(...)                   │         │  handle(...)        │
//    └─────────────────────────────┘         └─────────────────────┘
//
//  ─── Compile-time safety ────────────────────────────────────────────────
//
//  `RouterBuilder` is NOT Sendable — the Swift compiler refuses to
//  share it across actor boundaries, so route registration is
//  confined to a single thread by construction. No `Atomic<Bool>`
//  isFrozen flag, no precondition in `add()`, no `@unchecked` — the
//  invariant "no concurrent writes during the build phase" is
//  enforced by the type system.
//
//  `Router` is `Sendable` (no `@unchecked`): all of its stored
//  properties are `let`-bound arrays of `Sendable` value types
//  (`Route` contains `HandlerKind` closures typed `@Sendable`). Safe
//  to share between 12 event loops, no further synchronisation
//  needed.
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

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

import NIOCore
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

/// A registered route. Internal — built by `RouterBuilder`, stored
/// read-only in `Router`.
struct Route: Sendable {
    let method: HTTPMethod
    /// Pre-split segments for fast matching.
    let segments: [RouteSegment]
    /// Sync or async dispatch kind, with middleware already composed
    /// in by `RouterBuilder.build()`.
    let handler: HandlerKind
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
            return { ctx throws in
                switch before(ctx) {
                case .proceed:
                    return after(ctx, try next(ctx))
                case .shortCircuit(let response):
                    return after(ctx, response)
                }
            }
        }
        self.wrapAsync = { next in
            return { ctx async throws in
                switch before(ctx) {
                case .proceed:
                    return after(ctx, try await next(ctx))
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

// MARK: - RouterBuilder (mutable, NOT Sendable)

/// Mutable HTTP router builder. NOT `Sendable` — the compiler forbids
/// sharing it across actor boundaries, which confines route
/// registration to a single thread by construction.
///
/// Build a `Router` from a `RouterBuilder` via `build()`:
///
/// ```swift
/// let builder = RouterBuilder()
/// builder.get("/health") { _ in .plaintext("ok") }
/// builder.get("/users/:id") { ctx in ... }
/// builder.use(authMiddleware)
/// let router = builder.build()  // immutable, Sendable
/// try await server.start(router: router)
/// ```
///
/// After `build()`, the builder may be discarded or reused to build
/// another independent `Router` (each `build()` returns a fresh
/// snapshot of the current state — mutations after `build()` do not
/// affect previously-built routers).
public final class RouterBuilder {

    // MARK: - Storage (mutable; confined to the building thread)

    private var staticRoutes: [Route] = []

    /// Routes containing at least one `.param` segment, tried after
    /// the static partition.
    private var dynamicRoutes: [Route] = []

    /// Middleware chain applied around every handler. The chain is
    /// pre-composed at `build()` time so per-request dispatch is
    /// just "call the matched handler" — middleware wrapping is
    /// folded into the handler closure.
    private var middlewares: [Middleware] = []

    public init() {}

    // MARK: - Registration (sync handlers)

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

    // MARK: - Registration (async handlers)

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
        if case .other = method {
            preconditionFailure("Cannot register a route for .other — it would match every unknown method.")
        }
        let segments = Self.parsePattern(pattern)
        let route = Route(method: method, segments: segments, handler: kind)
        let isAllStatic = segments.allSatisfy {
            if case .literal = $0 { return true } else { return false }
        }
        if isAllStatic {
            staticRoutes.append(route)
        } else {
            dynamicRoutes.append(route)
        }
    }

    /// Append a middleware to the chain. Middlewares are invoked in
    /// registration order, outermost-first.
    public func use(_ middleware: Middleware) {
        self.middlewares.append(middleware)
    }

    // MARK: - Build

    /// Build an immutable `Router` snapshot from the current state.
    ///
    /// Performs middleware composition: each route's handler is
    /// wrapped in the registered middleware chain (sync fast path
    /// where possible). The result is an immutable, `Sendable`
    /// `Router` safe to share across event loops.
    ///
    /// The builder itself is not consumed — subsequent `add`/`use`
    /// calls affect only future `build()` invocations, not previously
    /// returned routers.
    public func build() -> Router {
        var staticRoutes = self.staticRoutes
        var dynamicRoutes = self.dynamicRoutes
        guard !middlewares.isEmpty else {
            return Router(staticRoutes: staticRoutes, dynamicRoutes: dynamicRoutes)
        }
        for i in staticRoutes.indices {
            staticRoutes[i] = Route(
                method: staticRoutes[i].method,
                segments: staticRoutes[i].segments,
                handler: composeOne(staticRoutes[i].handler)
            )
        }
        for i in dynamicRoutes.indices {
            dynamicRoutes[i] = Route(
                method: dynamicRoutes[i].method,
                segments: dynamicRoutes[i].segments,
                handler: composeOne(dynamicRoutes[i].handler)
            )
        }
        return Router(staticRoutes: staticRoutes, dynamicRoutes: dynamicRoutes)
    }

    /// Compose middleware chain around a single handler. Called only
    /// from `build()`, never per-request.
    ///
    /// Composition rules:
    /// - **Sync handler + all-middleware-have-wrapSync**: stays sync.
    ///   Zero async overhead — the fast path for typical apps.
    /// - **Sync handler + any-middleware-async-only**: promoted to async.
    ///   Overhead is one continuation hop (no Task allocation, no
    ///   executor hop under `NonisolatedNonsendingByDefault`).
    /// - **Async handler**: always composes via `wrapAsync`. Middleware
    ///   is fully applied.
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
            var h: AsyncHTTPHandler = { ctx async throws in try fn(ctx) }
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

    // MARK: - Pattern parsing (static — shared with Router)

    /// Parse a route pattern (e.g. `/users/:id`) into segments with
    /// pre-compiled bytes for zero-allocation matching. Walks UTF-8
    /// directly — no intermediate [Substring] or [String] arrays.
    static func parsePattern(_ pattern: String) -> [RouteSegment] {
        var segments: [RouteSegment] = []
        var utf8 = pattern.utf8[...]
        // Skip leading slashes.
        while utf8.first == 0x2F { utf8 = utf8.dropFirst() }

        while !utf8.isEmpty {
            // Find next '/' or end.
            let segmentEnd = utf8.firstIndex(of: 0x2F) ?? utf8.endIndex
            let part = utf8[..<segmentEnd]

            if part.first == 0x3A {  // ':'
                // Param — name needs a String for Params lookup.
                segments.append(.param(String(decoding: part.dropFirst(), as: UTF8.self)))
            } else if part.first == 0x2A {  // '*'
                // Catch-all — treated as literal for now.
                segments.append(.literal(Array(part)))
            } else {
                segments.append(.literal(Array(part)))
            }

            utf8 = utf8[segmentEnd...]
            while utf8.first == 0x2F { utf8 = utf8.dropFirst() }
        }
        return segments
    }
}

// MARK: - Router (immutable, Sendable)

/// Immutable HTTP request router. The output of `RouterBuilder.build()`.
///
/// Routes are stored in registration order. Static-segment routes are
/// tried before dynamic-segment routes when both can match — this is
/// implemented by partitioning routes at build time so the search
/// terminates as soon as a match is found.
///
/// `Sendable` without `@unchecked`: every stored property is a
/// `let`-bound array of `Sendable` value types. Safe to share between
/// event loops without further synchronisation.
public struct Router: Sendable {

    /// Routes whose pattern is entirely literal segments, tried first.
    private let staticRoutes: [Route]

    /// Routes containing at least one `.param` segment, tried after
    /// the static partition.
    private let dynamicRoutes: [Route]

    /// Internal-only initialiser — `RouterBuilder.build()` is the
    /// only way for application code to obtain a `Router`.
    internal init(staticRoutes: [Route], dynamicRoutes: [Route]) {
        self.staticRoutes = staticRoutes
        self.dynamicRoutes = dynamicRoutes
    }

    /// Number of registered routes. Useful for tests.
    public var routeCount: Int { staticRoutes.count + dynamicRoutes.count }

    // MARK: - Convenience init

    /// Build a `Router` from a configuration closure. Syntactic sugar
    /// over the explicit `RouterBuilder().build()` dance — the closure
    /// receives a fresh `RouterBuilder`, registers routes/middleware
    /// on it, and the resulting immutable snapshot is returned.
    ///
    /// ```swift
    /// let router = Router {
    ///     $0.get("/health") { _ in .plaintext("ok") }
    ///     $0.get("/users/:id") { ctx in ... }
    ///     $0.use(authMiddleware)
    /// }
    /// ```
    public init(_ configure: (RouterBuilder) -> Void) {
        let builder = RouterBuilder()
        configure(builder)
        self = builder.build()
    }

    // MARK: - Dispatch

    /// Dispatch a parsed request through the router.
    ///
    /// This is the entry point that `HTTP1Codec` calls once the
    /// request line + headers have been parsed. The router:
    ///   1. Matches `(ctx.method, ctx.path)` against the routes.
    ///   2. Populates `ctx.params` with any dynamic-segment captures.
    ///   3. Invokes the matched handler (sync or async).
    ///   4. Returns a 404 response if no route matched.
    ///
    /// Middleware is pre-composed at `RouterBuilder.build()` time —
    /// per-request dispatch is just "call the matched handler."
    ///
    /// `throws` propagates errors from the handler (or from
    /// middleware that doesn't catch them). The codec turns an
    /// uncaught error into a `500 Internal Server Error` response.
    public func handle(_ ctx: inout RequestContext) async throws -> HTTPResponse {
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
            return try fn(ctx)
        case .async(let fn):
            return try await fn(ctx)
        }
    }

    // MARK: - Matching

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
            // Path is already query-stripped by the parser — no '?' scan needed.
            let pathLen = total
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
        let pathOnly: String
        if let qIdx = path.firstIndex(of: "?") {
            pathOnly = String(path[..<qIdx])
        } else {
            pathOnly = path
        }
        var buf = ByteBufferAllocator().buffer(capacity: pathOnly.utf8.count)
        buf.writeString(pathOnly)
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
                let len = bytes.count
                guard pos + len <= pathLen else { return false }
                var matched: Bool
                if len >= 8 {
                    // memcmp for longer segments — glibc uses SIMD.
                    matched = bytes.withUnsafeBufferPointer { buf in
                        memcmp(path.advanced(by: pos), buf.baseAddress!, len) == 0
                    }
                } else {
                    // Inline for short segments — avoids call overhead.
                    matched = true
                    for i in 0..<len {
                        if path[pos + i] != bytes[i] { matched = false; break }
                    }
                }
                if !matched { return false }
                pos += len
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
}
