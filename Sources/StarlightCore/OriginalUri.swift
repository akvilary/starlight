//===----------------------------------------------------------------------===//
//
//  OriginalUri.swift
//  StarlightCore
//
//  Direct port of `axum::extract::OriginalUri`.
//
//  Captures the request's original URI before any middleware
//  modifications. Set by the server on every request.
//
//===----------------------------------------------------------------------===//

import Foundation
import HTTP

/// The original URI of the request, before any middleware
/// modifications (e.g. prefix stripping).
///
/// Direct port of `axum::extract::OriginalUri`. Useful when
/// middleware rewrites the path — `OriginalUri` preserves the
/// original for logging or redirects.
///
/// ```swift
/// router.get("/api/users") { (_: OriginalUri) in
///     // originalUri.value.pathString == "/api/users"
/// }
/// ```
public struct OriginalUri: Hashable, Sendable {
    public let value: Uri

    @inlinable public init(_ value: Uri) { self.value = value }
}

extension OriginalUri: FromRequestParts {
    public typealias State = AnySendable

    public static func fromRequestParts(
        _ parts: inout RequestParts<Body>,
        state: borrowing AnySendable
    ) async throws -> OriginalUri {
        // In our current implementation the URI is never modified
        // by middleware, so OriginalUri == parts.uri. But we still
        // provide it for axum API compatibility and future-proofing.
        if let original = parts.extensions.get(OriginalUri.self) {
            return original
        }
        return OriginalUri(parts.uri)
    }
}

/// Extension point for the server. Called on each request to stash
/// the original URI in extensions — matches axum's behaviour where
/// `serve()` inserts OriginalUri before routing.
@inlinable
public func setOriginalUri(_ uri: Uri, on request: inout Request<Body>) {
    request.extensions.insert(OriginalUri(uri))
}
