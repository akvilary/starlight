//===----------------------------------------------------------------------===//
//
//  RouteId.swift
//  StarlightRouting
//
//  Port of `axum::routing::RouteId`.
//
//===----------------------------------------------------------------------===//

import Foundation

/// Opaque identifier for a registered route.
///
/// Allocated monotonically by `RouterBuilder` during route
/// registration; used internally to map a matched path back to its
/// `MethodRouter` for method-not-allowed / options handling.
public struct RouteId: Sendable, Hashable, CustomStringConvertible {
    public let rawValue: UInt32

    @inlinable public init(_ raw: UInt32) { self.rawValue = raw }

    public var description: String { "RouteId(\(rawValue))" }
}
