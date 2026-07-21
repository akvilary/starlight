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
