//===----------------------------------------------------------------------===//
//
//  MatchedPath.swift
//  StarlightCore
//
//  Direct port of `axum::extract::MatchedPath`.
//
//  Represents the route pattern that matched the request — e.g.
//  request `/users/42` matched pattern `/users/:id`.
//
//  Set by the Router during path matching. Extracted by handlers
//  for metrics, logging, or conditional logic.
//
//===----------------------------------------------------------------------===//

import Foundation
import HTTP

/// The route pattern that matched the incoming request.
///
/// Direct port of `axum::extract::MatchedPath`. The router sets
/// this in `Request.extensions` during matching — handlers extract
/// it to know which pattern matched.
///
/// ```swift
/// // For request GET /users/42 with route /users/:id:
/// router.get("/users/:id") { (_: MatchedPath) in
///     // matchedPath.value == "/users/:id"
/// }
/// ```
public struct MatchedPath: Hashable, Sendable, CustomStringConvertible {
    public let value: String

    @inlinable public init(_ value: String) { self.value = value }

    public var description: String { value }
}

extension MatchedPath: FromRequestParts {
    public typealias State = AnySendable

    public static func fromRequestParts(
        _ parts: inout RequestParts<Body>,
        state: borrowing AnySendable
    ) async throws -> MatchedPath {
        guard let mp = parts.extensions.get(MatchedPath.self) else {
            throw ExtractionRejection(
                "MatchedPath not set — request didn't go through the Router",
                status: .internalServerError
            )
        }
        return mp
    }
}
