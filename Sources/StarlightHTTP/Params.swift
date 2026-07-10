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
//  ─── Zero-allocation design ────────────────────────────────────────────
//
//  Params stores byte-offset ranges into the request path ByteBuffer
//  rather than materialising String values during matching. The value
//  String is constructed on-demand only when the handler actually reads
//  a param via subscript — routes whose handlers never inspect params
//  (the common case for /health, static files, etc.) pay zero String
//  allocation.
//
//===----------------------------------------------------------------------===//

import NIOCore

/// Byte-offset-backed path-parameter storage. Used by `RequestContext.params`.
public struct Params: Sendable {
    /// Captured `(name, offset, length)` triples, in registration order
    /// along the route's pattern. `offset` and `length` refer to bytes
    /// in `backingBuffer`'s readable region (relative to readerIndex).
    @usableFromInline internal var ranges: [(name: String, offset: Int, length: Int)]

    /// COW reference to the path ByteBuffer that backs the offsets.
    /// Set by the router before matching. Stays alive as long as any
    /// Params value referencing it exists.
    @usableFromInline internal var backingBuffer: ByteBuffer?

    @inlinable
    public init() {
        self.ranges = []
        self.backingBuffer = nil
    }

    /// Look up the value captured for `name`. Returns `nil` if the
    /// route pattern did not declare a `:name` segment.
    ///
    /// The value String is materialised on-demand from the backing
    /// ByteBuffer — no allocation happens during route matching.
    ///
    /// - Complexity: O(ranges.count) for the search + O(length) for
    ///   String construction. For typical routes (0–2 params) this is
    ///   faster than a `Dictionary` because it avoids hashing overhead.
    @inlinable
    public subscript(name: String) -> String? {
        guard let buf = self.backingBuffer else { return nil }
        for r in self.ranges {
            if r.name == name {
                return buf.getString(at: buf.readerIndex + r.offset, length: r.length)
            }
        }
        return nil
    }

    /// Number of captured parameters.
    @inlinable
    public var count: Int { self.ranges.count }

    /// `true` if no parameters were captured (the route had no
    /// dynamic segments).
    @inlinable
    public var isEmpty: Bool { self.ranges.isEmpty }

    /// Record a param's byte range. Called by the router during
    /// matching — not intended for application code.
    @inlinable
    public mutating func appendParam(name: String, offset: Int, length: Int) {
        self.ranges.append((name, offset, length))
    }

    /// Set the backing ByteBuffer for on-demand value materialisation.
    /// Called by the router before matching — not intended for
    /// application code.
    @inlinable
    public mutating func setBackingBuffer(_ buf: ByteBuffer) {
        self.backingBuffer = buf
    }

    /// Remove all captured parameters. Used between keep-alive
    /// requests. Preserves capacity so subsequent requests on the
    /// same connection don't re-allocate the backing array.
    @inlinable
    public mutating func removeAll() {
        if !self.ranges.isEmpty {
            self.ranges.removeAll(keepingCapacity: true)
        }
        self.backingBuffer = nil
    }
}
