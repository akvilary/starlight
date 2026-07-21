//===----------------------------------------------------------------------===//
//
//  PathMatcher.swift
//  StarlightRouting
//
//  Path pattern matching — port of axum's use of the `matchit` crate.
//
//  Supports:
//
//    `/users/42`            → static match
//    `/users/:id`           → capture "42" into params["id"]
//    `/files/*path`         → catch-all (captures the rest of the path)
//
//  Static segments take priority over dynamic ones — if both
//  `/users/me` and `/users/:id` are registered, `/users/me`
//  matches the static route. This mirrors axum/matchit precedence.
//
//  The current implementation is linear scan + byte-wise match —
//  same as `matchit::Router` for low route counts. A proper radix
//  trie (O(path length) matching) lands in a later phase when
//  benchmarks show the linear scan dominating.
//
//===----------------------------------------------------------------------===//

import Foundation
import StarlightCore

/// One segment of a route pattern.
@usableFromInline
internal enum PathSegment: Sendable, Hashable {
    /// Static text — must match exactly. Pre-compiled UTF-8 bytes.
    case literal([UInt8])
    /// Named capture — matches any non-empty segment.
    case param(String)
    /// Catch-all — matches the rest of the path (may be empty).
    case wildcard(String)
}

/// Pre-compiled pattern. Stored by `Router` for matching.
public struct PathPattern: Sendable {
    public let raw: String
    @usableFromInline internal let segments: [PathSegment]
    /// `true` iff every segment is `.literal` — used to partition
    /// static and dynamic routes for the fast path.
    public let isAllStatic: Bool

    @inlinable
    public init(_ pattern: String) {
        self.raw = pattern
        let segs = Self.parse(pattern)
        self.segments = segs
        self.isAllStatic = segs.allSatisfy {
            if case .literal = $0 { return true } else { return false }
        }
    }

    /// Parse a route pattern like `/users/:id/files/*path` into
    /// typed segments. Walks UTF-8 bytes directly — no String slicing.
    @usableFromInline
    static func parse(_ pattern: String) -> [PathSegment] {
        var segments: [PathSegment] = []
        var utf8 = pattern.utf8[...]
        while utf8.first == 0x2F { utf8 = utf8.dropFirst() }  // '/'

        while !utf8.isEmpty {
            let end = utf8.firstIndex(of: 0x2F) ?? utf8.endIndex
            let part = utf8[..<end]

            if part.first == 0x3A {  // ':'
                segments.append(.param(String(decoding: part.dropFirst(), as: UTF8.self)))
            } else if part.first == 0x2A {  // '*'
                segments.append(.wildcard(String(decoding: part.dropFirst(), as: UTF8.self)))
            } else {
                segments.append(.literal(Array(part)))
            }
            utf8 = utf8[end...]
            while utf8.first == 0x2F { utf8 = utf8.dropFirst() }
        }
        return segments
    }

    /// Match `pathBytes` against the compiled segments. On success,
    /// populate `params` with captured values (URL-decoded) and return
    /// `true`. On failure, leave `params` unmodified and return `false`.
    ///
    /// `pathBytes` should be the path portion only (query/fragment
    /// already stripped).
    public func match(_ pathBytes: [UInt8], params: inout PathParams) -> Bool {
        var pos = 0
        let n = pathBytes.count
        for segment in segments {
            while pos < n && pathBytes[pos] == 0x2F { pos += 1 }
            switch segment {
            case .literal(let bytes):
                let len = bytes.count
                guard pos + len <= n else { return false }
                var matched = true
                for i in 0..<len {
                    if pathBytes[pos + i] != bytes[i] { matched = false; break }
                }
                if !matched { return false }
                pos += len

            case .param(let name):
                let start = pos
                while pos < n && pathBytes[pos] != 0x2F { pos += 1 }
                if pos == start { return false }
                let valueBytes = Array(pathBytes[start..<pos])
                params.set(name, value: Self.decode(valueBytes))

            case .wildcard(let name):
                let rest = Array(pathBytes[pos...])
                params.set(name, value: Self.decode(rest))
                return true
            }
        }
        return pos == n || (pos + 1 == n && pathBytes[pos] == 0x2F)
    }

    /// Percent-decode a captured value. For the skeleton, just UTF-8
    /// decode — full %XX-decode lands in the extractors phase.
    @inlinable
    static func decode(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }
}
