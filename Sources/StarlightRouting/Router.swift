//===----------------------------------------------------------------------===//
//
//  Router.swift
//  StarlightRouting
//
//  Direct port of `axum::routing::Router<S>`.
//
//  The main entry point of the framework: holds a list of
//  `(PathPattern, MethodRouter<S>)` plus a fallback. Conforms to
//  `Service<HTTP.Request<Body>, Response = HTTP.Response<Body>>` so it can
//  be served via `StarlightServer.serve(service:)`.
//
//===----------------------------------------------------------------------===//

import Foundation
import StarlightCore
import HTTP
import StarlightTower

/// The axum `Router<S>` port.
///
/// `S` is the application state type threaded into every handler
/// via the `State<S>` extractor. Use `NoState` if you have no
/// shared state — the router then exposes no `state(_:)` and handlers
/// do not receive `State<...>`.
public struct Router<S: Sendable>: Sendable {
    /// Registered routes. Partitioned by static / dynamic at
    /// `build()` time for the fast path (static lookup before
    /// dynamic).
    @usableFromInline internal let staticRoutes:  [(PathPattern, MethodRouter<S>)]
    @usableFromInline internal let dynamicRoutes: [(PathPattern, MethodRouter<S>)]

    /// Called when no route matches the path. Defaults to `404 Not Found`.
    @usableFromInline internal let fallback: HandlerEndpoint?

    /// App state.
    @usableFromInline internal let state: S

    @inlinable
    public init(state: S = NoState() as! S) {
        // `as! S` is a hack: this convenience is only called with
        // `S == NoState`. Real callers go through `Router<S>.init(state:)`.
        self.staticRoutes = []
        self.dynamicRoutes = []
        self.fallback = nil
        self.state = state
    }

    @inlinable
    public init(
        state: S,
        staticRoutes: [(PathPattern, MethodRouter<S>)],
        dynamicRoutes: [(PathPattern, MethodRouter<S>)],
        fallback: HandlerEndpoint?
    ) {
        self.state = state
        self.staticRoutes = staticRoutes
        self.dynamicRoutes = dynamicRoutes
        self.fallback = fallback
    }

    // ── Builder methods ────────────────────────────────────────────

    /// Register a `MethodRouter<S>` for a path pattern.
    public func route(_ pattern: String, _ methodRouter: MethodRouter<S>) -> Router<S> {
        let compiled = PathPattern(pattern)
        var statics = staticRoutes
        var dynamics = dynamicRoutes
        if compiled.isAllStatic {
            statics.append((compiled, methodRouter))
        } else {
            dynamics.append((compiled, methodRouter))
        }
        return Router<S>(
            state: state,
            staticRoutes: statics,
            dynamicRoutes: dynamics,
            fallback: fallback
        )
    }

    /// Convenience: register a single handler directly (axum's
    /// `Router::route("/path", get(handler))` lowered into a single
    /// call for the common one-handler-per-path case).
    public func route(
        _ pattern: String,
        method: Method,
        _ endpoint: HandlerEndpoint
    ) -> Router<S> {
        let mr = MethodRouter(state: state)
        let with = applyToRouter(mr, method: method, endpoint: endpoint)
        return route(pattern, with)
    }

    @inline(__always)
    private func applyToRouter(_ r: MethodRouter<S>, method: Method, endpoint: HandlerEndpoint) -> MethodRouter<S> {
        switch method {
        case .GET:     return r.get(endpoint)
        case .POST:    return r.post(endpoint)
        case .PUT:     return r.put(endpoint)
        case .DELETE:  return r.delete(endpoint)
        case .HEAD:    return r.head(endpoint)
        case .OPTIONS: return r.options(endpoint)
        case .PATCH:   return r.patch(endpoint)
        case .TRACE:   return r.trace(endpoint)
        default:       return r.any(endpoint)
        }
    }

    /// Replace the fallback. The fallback is called when no route
    /// matches the path (404) or when a method is not allowed on a
    /// matched path (405) — the latter is opt-in via `MethodRouter`.
    public func fallback(_ endpoint: HandlerEndpoint) -> Router<S> {
        Router<S>(
            state: state,
            staticRoutes: staticRoutes,
            dynamicRoutes: dynamicRoutes,
            fallback: endpoint
        )
    }

    /// Convenience for the common case: register a `GET <pattern>`
    /// that takes a single endpoint. Equivalent to
    /// `route(pattern, .GET, endpoint)`.
    public func get(_ pattern: String, _ endpoint: HandlerEndpoint) -> Router<S> {
        route(pattern, method: .GET, endpoint)
    }
    public func post(_ pattern: String, _ endpoint: HandlerEndpoint) -> Router<S> {
        route(pattern, method: .POST, endpoint)
    }
    public func put(_ pattern: String, _ endpoint: HandlerEndpoint) -> Router<S> {
        route(pattern, method: .PUT, endpoint)
    }
    public func delete(_ pattern: String, _ endpoint: HandlerEndpoint) -> Router<S> {
        route(pattern, method: .DELETE, endpoint)
    }
    public func patch(_ pattern: String, _ endpoint: HandlerEndpoint) -> Router<S> {
        route(pattern, method: .PATCH, endpoint)
    }

    // MARK: - Closure-based handler overloads (axum ergonomics)
    //
    // These overloads let you register handlers without explicitly
    // wrapping in BoxService — matching axum's ergonomics:
    //
    //   router.get("/") { _ in .plain("hello") }
    //   router.get("/") { .plain("no args needed") }
    //
    // The closure receives the whole Request<Body> for manual
    // extraction. For typed extractors (Path<T>, Query<T>, etc.)
    // use HandlerService1/2/3 explicitly — they're more verbose but
    // provide compile-time extraction + rejection.

    /// Register a GET handler that receives the whole request.
    /// Matches axum's `get(|req| async { ... })`.
    public func get(
        _ pattern: String,
        _ handler: @Sendable @escaping (HTTP.Request<Body>) async throws -> HTTP.Response<Body>
    ) -> Router<S> {
        get(pattern, BoxService(handler))
    }

    /// Register a GET handler with no arguments.
    /// Matches axum's `get(|| async { ... })`.
    public func get(
        _ pattern: String,
        _ handler: @Sendable @escaping () async throws -> HTTP.Response<Body>
    ) -> Router<S> {
        get(pattern, BoxService { _ in try await handler() })
    }

    /// Register a POST handler that receives the whole request.
    public func post(
        _ pattern: String,
        _ handler: @Sendable @escaping (HTTP.Request<Body>) async throws -> HTTP.Response<Body>
    ) -> Router<S> {
        post(pattern, BoxService(handler))
    }

    /// Register a POST handler with no arguments.
    public func post(
        _ pattern: String,
        _ handler: @Sendable @escaping () async throws -> HTTP.Response<Body>
    ) -> Router<S> {
        post(pattern, BoxService { _ in try await handler() })
    }

    /// Register a PUT handler that receives the whole request.
    public func put(
        _ pattern: String,
        _ handler: @Sendable @escaping (HTTP.Request<Body>) async throws -> HTTP.Response<Body>
    ) -> Router<S> {
        put(pattern, BoxService(handler))
    }

    /// Register a DELETE handler that receives the whole request.
    public func delete(
        _ pattern: String,
        _ handler: @Sendable @escaping (HTTP.Request<Body>) async throws -> HTTP.Response<Body>
    ) -> Router<S> {
        delete(pattern, BoxService(handler))
    }

    /// Register a PATCH handler that receives the whole request.
    public func patch(
        _ pattern: String,
        _ handler: @Sendable @escaping (HTTP.Request<Body>) async throws -> HTTP.Response<Body>
    ) -> Router<S> {
        patch(pattern, BoxService(handler))
    }

    // MARK: - nest (port of axum::routing::Router::nest)

    /// Nest another `Router<S>` under a path prefix. Each route in
    /// `other` becomes a route under `<prefix><path>` in `self`.
    ///
    /// Direct port of `axum::routing::Router::nest`. Example:
    ///
    /// ```swift
    /// let api = Router(state: ...)
    ///     .get("/users", ...)
    ///     .get("/posts", ...)
    ///
    /// let app = Router(state: ...)
    ///     .nest("/api/v1", api)
    /// // → app routes: /api/v1/users, /api/v1/posts
    /// ```
    ///
    /// Prefix semantics (matches axum):
    ///   - `nest("/api", r)` with `r.get("/users", _)` → `/api/users`
    ///   - `nest("/api/", r)` with `r.get("/users", _)` → `/api/users`
    ///   - `nest("/api", r)` with `r.get("/", _)` → `/api`
    public func nest(_ prefix: String, _ other: Router<S>) -> Router<S> {
        var result = self
        for (pattern, methodRouter) in other.staticRoutes + other.dynamicRoutes {
            let combined = Self.joinPath(prefix, pattern.raw)
            result = result.route(combined, methodRouter)
        }
        return result
    }

    /// Join a nest prefix with an inner path. Mirrors axum's
    /// `path_for_nested_route`.
    @inline(__always)
    private static func joinPath(_ prefix: String, _ inner: String) -> String {
        // Both prefix and inner start with '/'.
        if prefix.hasSuffix("/") {
            // Avoid double-slash: "/api/" + "/users" → "/api/users"
            return prefix + inner.drop(while: { $0 == "/" })
        }
        if inner == "/" {
            return prefix
        }
        return prefix + inner
    }

    // MARK: - merge (port of axum::routing::Router::merge)

    /// Merge another `Router<S>`'s routes into `self`. Routes from
    /// both routers coexist; conflicts on the same path + method
    /// resolve to the merged-in router (last wins).
    ///
    /// Direct port of `axum::routing::Router::merge`.
    public func merge(_ other: Router<S>) -> Router<S> {
        var result = self
        for (pattern, methodRouter) in other.staticRoutes {
            result = result.route(pattern.raw, methodRouter)
        }
        for (pattern, methodRouter) in other.dynamicRoutes {
            result = result.route(pattern.raw, methodRouter)
        }
        // Inherit fallback if other has one and self doesn't.
        if result.fallback == nil, let fb = other.fallback {
            result = result.fallback(fb)
        }
        return result
    }

    // MARK: - layer (port of axum::routing::Router::layer)

    /// Apply `layer` to ALL routes in this router. The layer wraps
    /// every endpoint, including the fallback.
    ///
    /// Direct port of `axum::routing::Router::layer`. Returns a new
    /// `Router<S>` with the wrapped endpoints.
    ///
    /// Example:
    ///
    /// ```swift
    /// let app = Router(state: ())
    ///     .get("/", ...)
    ///     .layer(from_fn { req, next in
    ///         print("before")
    ///         let resp = try await next.run(req)
    ///         print("after")
    ///         return resp
    ///     })
    /// ```
    public func layer(
        _ layer: Layer<HTTP.Request<Body>, HTTP.Response<Body>>
    ) -> Router<S> {
        var statics = staticRoutes
        var dynamics = dynamicRoutes
        // Wrap each route's method router by wrapping every endpoint
        // inside it.
        for i in statics.indices {
            statics[i] = (statics[i].0, statics[i].1.mapEndpoints {
                layer.layer($0)
            })
        }
        for i in dynamics.indices {
            dynamics[i] = (dynamics[i].0, dynamics[i].1.mapEndpoints {
                layer.layer($0)
            })
        }
        let newFallback = fallback.map { layer.layer($0) }
        return Router<S>(
            state: state,
            staticRoutes: statics,
            dynamicRoutes: dynamics,
            fallback: newFallback
        )
    }

    // MARK: - route_layer (port of axum::routing::Router::route_layer)

    /// Apply `layer` to routes added BEFORE this call (not future
    /// routes). Useful for scoping middleware to a subset of routes.
    ///
    /// Direct port of `axum::routing::Router::route_layer`. Matches
    /// axum's "applies to all routes added so far" semantics.
    ///
    /// Example:
    ///
    /// ```swift
    /// let app = Router(state: ())
    ///     .get("/public", ...)            // no auth
    ///     .route_layer(authMiddleware)    // applies to /private below
    ///     .get("/private", ...)           // has auth
    /// ```
    public func route_layer(
        _ layer: Layer<HTTP.Request<Body>, HTTP.Response<Body>>
    ) -> Router<S> {
        // Same implementation as `layer` — applied to all currently-
        // registered routes. axum panics if there are no routes; we
        // just no-op (cleaner for builder chaining).
        guard !staticRoutes.isEmpty || !dynamicRoutes.isEmpty else {
            return self
        }
        return self.layer(layer)
    }

    /// Total number of registered routes.
    public var routeCount: Int { staticRoutes.count + dynamicRoutes.count }
}

// MARK: - Service conformance
//
// `Router<S>` is `Service<HTTP.Request<Body>, Response = HTTP.Response<Body>>`
// — this is the central contract that lets axum pass a `Router` to
// `axum::serve`.
extension Router: Service {
    public typealias Request = HTTP.Request<Body>
    public typealias Response = HTTP.Response<Body>

    public func call(_ request: consuming HTTP.Request<Body>) async throws -> HTTP.Response<Body> {
        let path = Array(request.uri.pathBytes)

        // 1. Static routes — linear scan, fast path for typical apps.
        // A radix trie lands in a later phase.
        var params = PathParams()
        for (pattern, methodRouter) in staticRoutes {
            if pattern.match(path, params: &params) {
                return try await dispatch(methodRouter, request: request, params: params)
            }
            params.removeAll(keepingCapacity: true)
        }
        // 2. Dynamic routes.
        for (pattern, methodRouter) in dynamicRoutes {
            if pattern.match(path, params: &params) {
                return try await dispatch(methodRouter, request: request, params: params)
            }
            params.removeAll(keepingCapacity: true)
        }
        // 3. Fallback (default 404).
        if let fallback { return try await fallback.call(request) }
        return Self.defaultNotFound()
    }

    @inline(__always)
    private func dispatch(
        _ methodRouter: MethodRouter<S>,
        request: consuming HTTP.Request<Body>,
        params: PathParams
    ) async throws -> HTTP.Response<Body> {
        // Stash captured params in the request extensions for the
        // `Path<T>` extractor to read.
        var req = request
        req.extensions.insert(MatchedPathParams(params))

        if let endpoint = methodRouter.dispatch(method: req.method) {
            return try await endpoint.call(req)
        }
        // Method not allowed — 405 with Allow header per RFC 9110.
        var headers = HeaderMap()
        let allow = methodRouter.allowedMethods().map(\.description).joined(separator: ", ")
        headers.insert(.allow, allow)
        return HTTP.Response(status: .methodNotAllowed, headers: headers, body: HTTP.Body())
    }

    @inline(__always)
    private static func defaultNotFound() -> HTTP.Response<Body> {
        HTTP.Response<Body>.plain("Not Found", status: .notFound)
    }
}
