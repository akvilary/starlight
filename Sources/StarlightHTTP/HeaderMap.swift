//===----------------------------------------------------------------------===//
//
//  HeaderName.swift / HeaderValue.swift / HeaderMap.swift
//  StarlightHTTP
//
//  Direct port of `http::{HeaderName, HeaderValue, HeaderMap}`.
//
//===----------------------------------------------------------------------===//

import Foundation

/// HTTP header name (e.g. `Content-Type`, `Content-Length`).
///
/// Case-insensitive on comparison, case-preserving on display —
/// matching RFC 9110 §5.1. Stored as a `[UInt8]` lowercased for
/// the comparison fast path; the canonical form is materialised
/// on demand via `description`.
public struct HeaderName: Sendable, Hashable, CustomStringConvertible {
    @usableFromInline internal let bytes: [UInt8]

    @inlinable
    public init(_ name: String) {
        // Lowercase ASCII for the lookup fast path.
        // (RFC 9110: header names are case-insensitive.)
        self.bytes = name.utf8.map { b -> UInt8 in
            if b >= 0x41 && b <= 0x5A { return b + 32 }   // A-Z → a-z
            return b
        }
    }

    /// Construct from raw bytes — used by the parser to avoid a
    /// `String` round-trip on the hot path.
    @inlinable
    public init(lowercasedBytes bytes: [UInt8]) {
        self.bytes = bytes
    }

    public var description: String {
        String(decoding: bytes, as: UTF8.self)
    }
}

extension HeaderName {
    // ── Common names (RFC 9110 §15 + extensions) ─────────────────
    public static let accept          = HeaderName("accept")
    public static let acceptEncoding  = HeaderName("accept-encoding")
    public static let allow           = HeaderName("allow")
    public static let authorization   = HeaderName("authorization")
    public static let cacheControl    = HeaderName("cache-control")
    public static let connection      = HeaderName("connection")
    public static let contentLength   = HeaderName("content-length")
    public static let contentType     = HeaderName("content-type")
    public static let cookie          = HeaderName("cookie")
    public static let date            = HeaderName("date")
    public static let etag            = HeaderName("etag")
    public static let expect          = HeaderName("expect")
    public static let host            = HeaderName("host")
    public static let ifMatch         = HeaderName("if-match")
    public static let ifModifiedSince = HeaderName("if-modified-since")
    public static let ifNoneMatch     = HeaderName("if-none-match")
    public static let location        = HeaderName("location")
    public static let range           = HeaderName("range")
    public static let server          = HeaderName("server")
    public static let setCookie       = HeaderName("set-cookie")
    public static let transferEncoding = HeaderName("transfer-encoding")
    public static let userAgent       = HeaderName("user-agent")
}

/// HTTP header value (the bytes after the `:`).
///
/// Stored as raw bytes — visible ASCII per RFC 9110 §5.5, but we
/// do not enforce visibility at the type level (callers may inject
/// opaque bytes for `Set-Cookie`, `Sec-WebSocket-*`, etc.). The
/// `String` form is materialised on demand via `description`.
public struct HeaderValue: Sendable, Hashable, CustomStringConvertible {
    public let bytes: [UInt8]

    @inlinable
    public init(_ value: String) {
        // RFC 9110 §5.5: optional leading/trailing whitespace is
        // trimmed by recipients. We do that here so `.host` lookups
        // never see `"  example.com  "`.
        let trimmed = Substring(value).drop(while: { $0.isWhitespace })
        // Inline trailing-whitespace trim — kept inline (rather than
        // in a `private extension Substring`) so this `@inlinable`
        // initialiser can call it across module boundaries.
        var end = trimmed.endIndex
        while end > trimmed.startIndex {
            let prev = trimmed.index(before: end)
            if !trimmed[prev].isWhitespace { break }
            end = prev
        }
        let stripped = trimmed[trimmed.startIndex..<end]
        self.bytes = Array(stripped.utf8)
    }

    @inlinable
    public init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    public var description: String {
        String(decoding: bytes, as: UTF8.self)
    }
}

/// Case-insensitive, insertion-ordered multimap of headers.
///
/// Mirrors `http::HeaderMap` (which itself mirrors hyper's
/// `HeaderMap`). Multiple values per name are supported — important
/// for `Set-Cookie` and `Cache-Control`.
public struct HeaderMap: Sendable {
    /// Backing storage: array of `(name, value)` pairs in insertion
    /// order. Linear scan on lookup is faster than `Dictionary` for
    /// typical HTTP header counts (3-12 headers/request).
    @usableFromInline internal var entries: [(HeaderName, HeaderValue)] = []

    @inlinable public init() {}

    @inlinable public init<S: Sequence>(_ entries: S) where S.Element == (HeaderName, HeaderValue) {
        self.entries = Array(entries)
    }

    /// Number of stored header entries (counting multiple values
    /// for the same name separately).
    @inlinable public var count: Int { entries.count }
    @inlinable public var isEmpty: Bool { entries.isEmpty }

    /// Append a header value. Does not replace existing values for
    /// the same name — multiple `append`s for `Set-Cookie` build up
    /// the expected list. Matches `http::HeaderMap::append`.
    @inlinable
    public mutating func append(_ name: HeaderName, _ value: HeaderValue) {
        entries.append((name, value))
    }

    @inlinable
    public mutating func append(_ name: HeaderName, _ value: String) {
        append(name, HeaderValue(value))
    }

    /// Insert a header value, removing any existing values for the
    /// same name first. Matches `http::HeaderMap::insert`.
    @inlinable
    public mutating func insert(_ name: HeaderName, _ value: HeaderValue) {
        entries.removeAll { $0.0 == name }
        entries.append((name, value))
    }

    @inlinable
    public mutating func insert(_ name: HeaderName, _ value: String) {
        insert(name, HeaderValue(value))
    }

    /// First value for `name`, or `nil` if absent. axum's typed
    /// header extractors (`TypedHeader<T>`) use this as the lookup.
    @inlinable
    public func first(for name: HeaderName) -> HeaderValue? {
        for (n, v) in entries where n == name { return v }
        return nil
    }

    /// All values for `name`. Order preserved.
    @inlinable
    public func all(for name: HeaderName) -> [HeaderValue] {
        entries.compactMap { $0.0 == name ? $0.1 : nil }
    }

    /// True if any entry matches `name`.
    @inlinable
    public func contains(_ name: HeaderName) -> Bool {
        entries.contains { $0.0 == name }
    }

    /// Remove all entries for `name`. Returns the removed count.
    @discardableResult
    @inlinable
    public mutating func remove(_ name: HeaderName) -> Int {
        let before = entries.count
        entries.removeAll { $0.0 == name }
        return before - entries.count
    }
}

extension HeaderMap: Equatable {
    @inlinable
    public static func == (lhs: HeaderMap, rhs: HeaderMap) -> Bool {
        guard lhs.entries.count == rhs.entries.count else { return false }
        for (i, (ln, lv)) in lhs.entries.enumerated() {
            let (rn, rv) = rhs.entries[i]
            if ln != rn || lv != rv { return false }
        }
        return true
    }
}
