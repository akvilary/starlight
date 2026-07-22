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
    public typealias State = S

    public static func fromRequestParts(
        _ parts: inout RequestParts,
        state: borrowing S
    ) async throws -> StarlightExtractors.State<S> {
        StarlightExtractors.State(copy state)
    }
}
