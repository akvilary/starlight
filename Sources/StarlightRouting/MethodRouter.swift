//===----------------------------------------------------------------------===//
//
//  MethodRouter.swift
//  StarlightRouting
//
//  Port of `axum::routing::MethodRouter<S>`.
//
//  A `MethodRouter` holds up to one handler per HTTP method, plus a
//  fallback. It is the per-path entry in a `Router` — when a path
//  matches, the matched `MethodRouter` dispatches by method.
//
//  `MethodRouter` itself conforms to `Service<Request, Response>`:
//  its `call(_:)` selects the handler matching `request.method`,
//  returning 405 Method Not Allowed if no handler matches (subject
//  to the configured `fallback`).
//
//===----------------------------------------------------------------------===//

import Foundation
import StarlightCore
import HTTP
import HTTPPrism

/// Per-method handler dispatch for a single path.
///
/// Constructed via `MethodRouter<S>.new()` or the per-method helpers
/// (`.get(_)`, `.post(_)` etc.). A `Router<S>` is conceptually
/// `[(PathPattern, MethodRouter<S>)]`.
public struct MethodRouter<S: Sendable>: Sendable {
    @usableFromInline internal var get:     HandlerEndpoint?
    @usableFromInline internal var put:     HandlerEndpoint?
    @usableFromInline internal var post:    HandlerEndpoint?
    @usableFromInline internal var delete:  HandlerEndpoint?
    @usableFromInline internal var head:    HandlerEndpoint?
    @usableFromInline internal var options: HandlerEndpoint?
    @usableFromInline internal var patch:   HandlerEndpoint?
    @usableFromInline internal var trace:   HandlerEndpoint?
    @usableFromInline internal var any:     HandlerEndpoint?

    /// Called when none of the per-method handlers match. Default:
    /// `405 Method Not Allowed`.
    @usableFromInline internal var fallback: HandlerEndpoint?

    /// App state forwarded to handlers.
    @usableFromInline internal let state: S

    @inlinable
    public init(state: S) {
        self.state = state
    }

    // ── Per-method setters ─────────────────────────────────────────

    public func get(_ svc: HandlerEndpoint) -> Self { mutate { $0.get = svc } }
    public func put(_ svc: HandlerEndpoint) -> Self { mutate { $0.put = svc } }
    public func post(_ svc: HandlerEndpoint) -> Self { mutate { $0.post = svc } }
    public func delete(_ svc: HandlerEndpoint) -> Self { mutate { $0.delete = svc } }
    public func head(_ svc: HandlerEndpoint) -> Self { mutate { $0.head = svc } }
    public func options(_ svc: HandlerEndpoint) -> Self { mutate { $0.options = svc } }
    public func patch(_ svc: HandlerEndpoint) -> Self { mutate { $0.patch = svc } }
    public func trace(_ svc: HandlerEndpoint) -> Self { mutate { $0.trace = svc } }

    /// Register a service that handles every method — overrides
    /// per-method services. axum calls this `MethodRouter::any`.
    public func any(_ svc: HandlerEndpoint) -> Self { mutate { $0.any = svc } }

    /// Register a fallback when no method matches.
    public func fallback(_ svc: HandlerEndpoint) -> Self { mutate { $0.fallback = svc } }

    /// Apply `transform` to every endpoint in this router. Used by
    /// `Router.layer(_:)` to wrap each method-specific handler in
    /// middleware.
    ///
    /// Direct port of axum's `MethodRouter::map` (internal) — the
    /// public API is `Router::layer` which calls this.
    public func mapEndpoints(
        _ transform: @Sendable @escaping (HandlerEndpoint) -> HandlerEndpoint
    ) -> MethodRouter<S> {
        mutate {
            if let v = $0.get     { $0.get     = transform(v) }
            if let v = $0.put     { $0.put     = transform(v) }
            if let v = $0.post    { $0.post    = transform(v) }
            if let v = $0.delete  { $0.delete  = transform(v) }
            if let v = $0.head    { $0.head    = transform(v) }
            if let v = $0.options { $0.options = transform(v) }
            if let v = $0.patch   { $0.patch   = transform(v) }
            if let v = $0.trace   { $0.trace   = transform(v) }
            if let v = $0.any     { $0.any     = transform(v) }
            if let v = $0.fallback { $0.fallback = transform(v) }
        }
    }

    /// Merge another MethodRouter into this one. Each method slot is
    /// filled from whichever router has a handler. Panics if both
    /// have a handler for the same method (duplicate registration),
    /// or if the result has both `any` and per-method handlers
    /// (the per-method handler would be unreachable dead code).
    public func merge(_ other: MethodRouter<S>) -> MethodRouter<S> {
        mutate { dst in
            func slot(_ existing: HandlerEndpoint?, _ incoming: HandlerEndpoint?, _ name: String) -> HandlerEndpoint? {
                if let incoming {
                    precondition(existing == nil,
                        "MethodRouter.merge: duplicate \(name) — already registered for this path")
                    return incoming
                }
                return existing
            }
            dst.get     = slot(dst.get, other.get, "GET")
            dst.put     = slot(dst.put, other.put, "PUT")
            dst.post    = slot(dst.post, other.post, "POST")
            dst.delete  = slot(dst.delete, other.delete, "DELETE")
            dst.head    = slot(dst.head, other.head, "HEAD")
            dst.options = slot(dst.options, other.options, "OPTIONS")
            dst.patch   = slot(dst.patch, other.patch, "PATCH")
            dst.trace   = slot(dst.trace, other.trace, "TRACE")
            dst.any     = slot(dst.any, other.any, "ANY")
            dst.fallback = slot(dst.fallback, other.fallback, "fallback")

            // Reject any + per-method coexistence — per-method handlers
            // would be dead code (dispatch always returns `any` first).
            if dst.any != nil {
                let perMethod: [HandlerEndpoint?] = [
                    dst.get, dst.put, dst.post, dst.delete,
                    dst.head, dst.options, dst.patch, dst.trace,
                ]
                if perMethod.contains(where: { $0 != nil }) {
                    preconditionFailure(
                        "MethodRouter.merge: 'any' handler cannot coexist with per-method handlers (dead code)"
                    )
                }
            }
        }
    }

    @usableFromInline
    internal func mutate(_ body: (inout Self) -> Void) -> Self {
        var copy = self
        body(&copy)
        return copy
    }

    /// Dispatch a request, selecting the handler matching `request.method`.
    ///
    /// axum's `MethodRouter::call` does exactly this. The 405 fallback
    /// includes an `Allow` header enumerating the supported methods,
    /// matching RFC 9110 §15.5.5.
    public func dispatch(method: Method) -> HandlerEndpoint? {
        if let any { return any }
        switch method {
        case .GET, .HEAD:
            // HEAD falls back to GET if no explicit HEAD handler.
            return head ?? get
        case .POST:    return post
        case .PUT:     return put
        case .DELETE:  return delete
        case .OPTIONS: return options
        case .PATCH:   return patch
        case .TRACE:   return trace
        default:       return fallback
        }
    }

    /// Enumerate the methods supported by this router — used to build
    /// the `Allow` header on a 405 response.
    public func allowedMethods() -> [Method] {
        var m: [Method] = []
        if get     != nil { m.append(.GET) }
        if put     != nil { m.append(.PUT) }
        if post    != nil { m.append(.POST) }
        if delete  != nil { m.append(.DELETE) }
        if head    != nil { m.append(.HEAD) }
        if options != nil { m.append(.OPTIONS) }
        if patch   != nil { m.append(.PATCH) }
        if trace   != nil { m.append(.TRACE) }
        return m
    }
}

/// Type-erased `Service<Request, Response = Response>` —
/// what a route handler becomes after passing through `Router<S>.get(_:)`.
public typealias HandlerEndpoint = BoxService<Request, Response>
