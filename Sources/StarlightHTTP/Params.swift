//===----------------------------------------------------------------------===//
//
//  Params.swift
//  StarlightHTTP
//
//  Path-parameter storage for `RequestContext`. Lives here (rather
//  than in `StarlightRouting`) so that `RequestContext` in
//  `StarlightHTTP` can store a `Params` value without a circular
//  module dependency.
//
//===----------------------------------------------------------------------===//

/// Array-backed path-parameter storage. Used by `RequestContext.params`.
public struct Params: Sendable {
    /// The captured `(name, value)` pairs, in registration order along
    /// the route's pattern. Public so callers can iterate without
    /// going through the subscript when they want all params at once.
    public var entries: [(name: String, value: String)]

    @inlinable
    public init() {
        self.entries = []
    }

    /// Look up the value captured for `name`. Returns `nil` if the
    /// route pattern did not declare a `:name` segment.
    ///
    /// - Complexity: O(entries.count). For typical routes (0–2 params)
    ///   this is faster than a `Dictionary` because it avoids the
    ///   hashing overhead on every lookup.
    @inlinable
    public subscript(name: String) -> String? {
        for entry in self.entries {
            if entry.name == name { return entry.value }
        }
        return nil
    }

    /// Number of captured parameters.
    @inlinable
    public var count: Int { self.entries.count }

    /// `true` if no parameters were captured (the route had no
    /// dynamic segments).
    @inlinable
    public var isEmpty: Bool { self.entries.isEmpty }

    /// Append a captured parameter. Used by the router during match.
    @inlinable
    public mutating func append(name: String, value: String) {
        self.entries.append((name, value))
    }

    /// Remove all captured parameters. Used between keep-alive
    /// requests.
    @inlinable
    public mutating func removeAll() {
        if !self.entries.isEmpty {
            self.entries.removeAll(keepingCapacity: false)
        }
    }
}
