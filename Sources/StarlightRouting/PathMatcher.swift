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

    /// Percent-decode captured path parameter bytes per RFC 3986 §2.1.
    ///
    /// `%XX` (where XX are hex digits) → single byte. All other bytes
    /// pass through. After all `%XX` sequences are decoded, the result
    /// is interpreted as UTF-8.
    ///
    /// **`+` is NOT decoded** as space — in path components `+` is a
    /// literal character (per RFC 3986). Only query-string parsing
    /// treats `+` as space.
    ///
    /// **Malformed `%`** (not followed by two hex digits) is treated
    /// as a literal `%` character — lenient, matching most web
    /// frameworks.
    ///
    /// **Fast path:** if no `%` byte is present, skips the byte-by-byte
    /// walk and decodes directly as UTF-8. This covers the vast
    /// majority of real-world path parameters (numeric IDs, slugs).
    @inlinable
    static func decode(_ bytes: [UInt8]) -> String {
        // Fast path: no percent-encoding → direct UTF-8 decode.
        if !bytes.contains(0x25) {
            return String(decoding: bytes, as: UTF8.self)
        }
        // Slow path: byte-by-byte percent-decode.
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x25,               // '%'
               i + 2 < bytes.count,
               let hi = hexDigit(bytes[i + 1]),
               let lo = hexDigit(bytes[i + 2]) {
                out.append(hi << 4 | lo)
                i += 3
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    @inlinable
    static func hexDigit(_ b: UInt8) -> UInt8? {
        switch b {
        case 0x30...0x39: return b - 0x30       // 0-9
        case 0x41...0x46: return b - 0x41 + 10  // A-F
        case 0x61...0x66: return b - 0x61 + 10  // a-f
        default: return nil
        }
    }
}
