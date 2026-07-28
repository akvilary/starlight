//===----------------------------------------------------------------------===//
//
//  State.swift
//  StarlightExtractors
//
//  Direct port of `axum::extract::State<S>`.
//
//===----------------------------------------------------------------------===//

import Foundation
import StarlightCore
import HTTP

/// Extractor for the application state.
///
/// Wraps the `S` the `Router<S>` was constructed with. axum's
/// `State<S>` works exactly this way: it's a transparent newtype
/// the handler receives to access shared config, connection pools,
/// etc.
public struct State<S: Sendable>: Sendable {
    public let value: S

    @inlinable public init(_ value: S) { self.value = value }
}

extension State: FromRequestParts {
    public static func fromRequestParts<AppState: Sendable>(
        _ parts: inout RequestParts,
        state: borrowing AppState
    ) async throws -> State<S> {
        // The state passed by HandlerService is the Router's state
        // type. If it matches our S, wrap it. If not, the handler
        // was registered on a router with a different state type —
        // a configuration error.
        if let typed = copy state as? S {
            return State(typed)
        }
        throw ExtractionRejection(
            "State type mismatch: expected \(S.self)",
            status: .internalServerError
        )
    }
}
