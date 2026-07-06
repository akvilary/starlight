//===----------------------------------------------------------------------===//
//
//  Router.swift
//  StarlightRouting
//
//  Phase 0 placeholder — the real radix-trie router (axum/matchit-style) lands
//  in Phase 4. This module exists so `StarlightServer` can compile against a
//  stable `Router` API surface today.
//
//===----------------------------------------------------------------------===//

import StarlightCore
import StarlightHTTP

/// Placeholder router: dispatches every request to a single registered
/// handler. The real router will be a path-parameterized radix trie that
/// returns borrowed `Span<UInt8>` parameter views, with zero allocations per
/// match (à la Rust's `matchit`).
public final class Router<Response: Sendable>: @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPMethod, String) async -> Response

    public let handler: Handler

    @inlinable
    public init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    @inlinable
    public func dispatch(method: HTTPMethod, path: String) async -> Response {
        return await self.handler(method, path)
    }
}
