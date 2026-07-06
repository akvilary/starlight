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
enum RouteSegment: Equatable {
    /// Static text — must match exactly.
    case literal(String)
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
    let handler: HTTPHandler
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
public final class Router: @unchecked Sendable {
    /// User handlers indexed by route. Searched linearly.
    private var routes: [Route] = []

    /// Middleware chain applied around every handler. The chain is
    /// pre-composed at `makeHandler()` time so per-request dispatch is
    /// just "call the matched handler" — middleware wrapping is
    /// folded into the handler closure.
    private var middlewares: [Middleware] = []

    public init() {}

    // MARK: - Registration

    /// Register a handler for `GET <pattern>`.
    public func get(_ pattern: String, _ handler: @escaping HTTPHandler) {
        self.add(.GET, pattern, handler)
    }

    /// Register a handler for `POST <pattern>`.
    public func post(_ pattern: String, _ handler: @escaping HTTPHandler) {
        self.add(.POST, pattern, handler)
    }

    /// Register a handler for `PUT <pattern>`.
    public func put(_ pattern: String, _ handler: @escaping HTTPHandler) {
        self.add(.PUT, pattern, handler)
    }

    /// Register a handler for `PATCH <pattern>`.
    public func patch(_ pattern: String, _ handler: @escaping HTTPHandler) {
        self.add(.PATCH, pattern, handler)
    }

    /// Register a handler for `DELETE <pattern>`.
    public func delete(_ pattern: String, _ handler: @escaping HTTPHandler) {
        self.add(.DELETE, pattern, handler)
    }

    /// Register a handler for `HEAD <pattern>`.
    public func head(_ pattern: String, _ handler: @escaping HTTPHandler) {
        self.add(.HEAD, pattern, handler)
    }

    /// Register a handler for `OPTIONS <pattern>`.
    public func options(_ pattern: String, _ handler: @escaping HTTPHandler) {
        self.add(.OPTIONS, pattern, handler)
    }

    /// Register a handler for an arbitrary method + pattern.
    public func add(_ method: HTTPMethod, _ pattern: String, _ handler: @escaping HTTPHandler) {
        let segments = Self.parsePattern(pattern)
        routes.append(Route(method: method, pattern: pattern, segments: segments, handler: handler))
    }

    /// Append a middleware to the chain. Middlewares are invoked in
    /// registration order, outermost-first.
    public func use(_ middleware: Middleware) {
        self.middlewares.append(middleware)
    }

    // MARK: - Dispatch

    /// Dispatch a parsed request through the router.
    ///
    /// This is the entry point that `HTTP1Codec` calls once the
    /// request line + headers have been parsed. The router:
    ///   1. Matches `(ctx.method, ctx.path)` against the routes.
    ///   2. Populates `ctx.params` with any dynamic-segment captures.
    ///   3. Invokes the matched handler (with middleware wrapping).
    ///   4. Returns a 404 response if no route matched.
    public func handle(_ ctx: inout RequestContext) -> HTTPResponse {
        let (method, path) = (ctx.method, ctx.path)
        guard let match = match(method: method, path: path) else {
            return HTTPResponse.plaintext(
                "404 Not Found: \(method) \(path)\n",
                status: HTTPStatus(404, reasonPhrase: "Not Found"),
                keepAlive: false
            )
        }
        ctx.params = match.params

        // Compose middleware around the matched handler. The
        // composition happens per-request but is just function
        // wrapping — no allocation when the closures are inlinable.
        // Phase 4 will pre-compose the chain at registration time.
        var handler: HTTPHandler = match.handler
        for mw in self.middlewares.reversed() {
            handler = mw.wrap(handler)
        }
        return handler(ctx)
    }

    // MARK: - Internal matching

    /// Match `(method, path)` against the registered routes and return
    /// the matching handler + extracted params. Returns `nil` if no
    /// route matched.
    public func match(method: HTTPMethod, path: String) -> (handler: HTTPHandler, params: [String: String])? {
        // Strip the query string if present — the router matches on
        // the path component only.
        let pathOnly: String
        if let q = path.firstIndex(of: "?") {
            pathOnly = String(path[path.startIndex..<q])
        } else {
            pathOnly = path
        }
        let requestSegments = Self.splitPath(pathOnly)

        // First pass: prefer fully-static routes.
        for route in routes where route.method == method {
            let isAllStatic = route.segments.allSatisfy {
                if case .literal = $0 { return true } else { return false }
            }
            if !isAllStatic { continue }
            if let params = Self.matchSegments(route.segments, requestSegments) {
                return (route.handler, params)
            }
        }
        // Second pass: routes with any dynamic segments.
        for route in routes where route.method == method {
            let isAllStatic = route.segments.allSatisfy {
                if case .literal = $0 { return true } else { return false }
            }
            if isAllStatic { continue }
            if let params = Self.matchSegments(route.segments, requestSegments) {
                return (route.handler, params)
            }
        }
        return nil
    }

    // MARK: - Pattern / path parsing

    /// Split a URL path into non-empty segments.
    static func splitPath(_ path: String) -> [String] {
        var segments: [String] = []
        var current = ""
        for byte in path.utf8 {
            if byte == 0x2F {  // '/'
                if !current.isEmpty {
                    segments.append(current)
                    current = ""
                }
            } else {
                current.append(Character(UnicodeScalar(byte)))
            }
        }
        if !current.isEmpty {
            segments.append(current)
        }
        return segments
    }

    /// Parse a route pattern (e.g. `/users/:id`) into segments.
    static func parsePattern(_ pattern: String) -> [RouteSegment] {
        let parts = splitPath(pattern)
        return parts.map { part in
            if part.hasPrefix(":") {
                return .param(String(part.dropFirst()))
            } else {
                return .literal(part)
            }
        }
    }

    /// Match a request's path segments against a route's pattern segments.
    /// Returns the captured params if the segments match, otherwise nil.
    static func matchSegments(_ pattern: [RouteSegment], _ request: [String]) -> [String: String]? {
        guard pattern.count == request.count else { return nil }
        var params: [String: String] = [:]
        for (p, r) in zip(pattern, request) {
            switch p {
            case .literal(let s):
                if s != r { return nil }
            case .param(let name):
                params[name] = r
            }
        }
        return params
    }

    /// Number of registered routes. Useful for tests.
    public var routeCount: Int { self.routes.count }
}
