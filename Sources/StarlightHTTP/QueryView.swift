//===----------------------------------------------------------------------===//
//
//  QueryView.swift
//  StarlightHTTP
//
//  Read-only view over the URL query string captured by the parser.
//  Zero per-request overhead in the common case where the handler does
//  not read any query parameters.
//
//  ─── Design ─────────────────────────────────────────────────────────────
//
//  The parser copies the query string (everything after `?` in the
//  request target, up to the first SP) into a reusable `ByteBuffer`
//  via `copyBlock(...)`, then QueryView walks that block on demand.
//  The query string is in `application/x-www-form-urlencoded` format:
//
//      key1=value1&key2=value2&key3
//
//  Pairs are separated by `&` (0x26). Within a pair, the first `=`
//  (0x3D) separates key from value. A pair with no `=` is treated as
//  a key with an empty value.
//
//  Lookup is case-sensitive (RFC 3986 does not mandate case-folding
//  for the query component — `?Foo=1` and `?foo=1` are distinct keys,
//  matching Express, Flask, Echo, Go net/http).
//
//  Values are URL-decoded on materialisation:
//    - `%XX` sequences are decoded to the byte 0xXX.
//    - `+` is decoded to space (0x20), per the
//      `application/x-www-form-urlencoded` convention used by every
//      browser and form library.
//    - Raw bytes (including multi-byte UTF-8 sequences) pass through
//      unchanged. `String(decoding:as:UTF8.self)` interprets them as
//      a UTF-8 String at the end, so Cyrillic / CJK / emoji values
//      work whether the client %-encoded them (`?name=%D0%98%D0%B2…`)
//      or sent them raw (`?name=Иван`).
//
//  ─── Zero-allocation fast path ──────────────────────────────────────────
//
//  When a value contains no `%` or `+` bytes (very common for short
//  ASCII values like ids, slugs, flags), the String is constructed
//  directly from the slice — no intermediate `[UInt8]` allocation.
//  Allocation happens only when decoding is actually needed.
//
//===----------------------------------------------------------------------===//

import NIOCore

/// Read-only view over the URL query string.
///
/// Backed by a single contiguous `ByteBuffer` holding the raw
/// (still-encoded) query bytes. Subscript access scans the block on
/// demand, matches the key case-sensitively, URL-decodes the value,
/// and materialises it as a `String`.
public struct QueryView: Sendable {
    /// The query string data, still %-encoded. Reusable across
    /// keep-alive requests — `copyBlock` clears and refills it, and
    /// `removeAll` resets it.
    @usableFromInline internal var block: ByteBuffer

    @inlinable
    public init() {
        self.block = ByteBufferAllocator().buffer(capacity: 0)
    }

    /// Copy `count` bytes from `buffer` (starting at `offset`) into
    /// the query block. Called once by the parser after it has
    /// identified the query string slice. The ByteBuffer is cleared
    /// first and then written — its storage grows as needed and is
    /// reused across keep-alive requests (no per-request allocation
    /// after the first query-bearing request on a connection).
    @inlinable
    internal mutating func copyBlock(
        from buffer: UnsafeBufferPointer<UInt8>,
        offset: Int,
        count: Int
    ) {
        self.block.clear()
        guard count > 0 else { return }
        self.block.writeBytes(UnsafeBufferPointer(
            start: buffer.baseAddress!.advanced(by: offset),
            count: count
        ))
    }

    /// Span-based overload (SE-0447). Same semantics as the
    /// `UnsafeBufferPointer` version, but the source is a borrowing
    /// `Span<UInt8>` — the parser's preferred input form.
    @inlinable
    internal mutating func copyBlock(
        from span: borrowing Span<UInt8>,
        offset: Int,
        count: Int
    ) {
        self.block.clear()
        guard count > 0 else { return }
        // Bridge the Span to UnsafeBufferPointer for direct writeBytes.
        // The bridge is zero-allocation (UnsafeBufferPointer is a
        // stack struct over the span's storage).
        span.withUnsafeBufferPointer { ptr in
            self.block.writeBytes(UnsafeBufferPointer(
                start: ptr.baseAddress!.advanced(by: offset),
                count: count
            ))
        }
    }

    // MARK: - Public lookup API

    /// Look up the first value for `name`, URL-decoded. Returns `nil`
    /// if the key was not present in the query string.
    ///
    /// - Complexity: O(blockLen) byte comparisons for the search +
    ///   O(valueLen) for URL-decoding. For typical queries with 1–4
    ///   parameters this is faster than parsing the whole string into
    ///   a `Dictionary`.
    public subscript(_ name: String) -> String? {
        guard self.block.readableBytes > 0 else { return nil }
        return self.block.withUnsafeReadableBytes { rawBytes -> String? in
            rawBytes.withMemoryRebound(to: UInt8.self) { typedBytes -> String? in
                guard let base = typedBytes.baseAddress else { return nil }
                guard let (start, len) = QueryView.findBytes(
                    name: name, in: base, length: typedBytes.count
                ) else { return nil }
                return QueryView.decodeValue(
                    UnsafeBufferPointer(start: base.advanced(by: start), count: len)
                )
            }
        }
    }

    /// Call `body` for each URL-decoded value of `name`, in
    /// insertion order. Zero-allocation on the caller side: no
    /// `[String]` array is created. Use for multi-valued parameters
    /// like `?id=1&id=2&id=3`.
    public func forEachValue(of name: String, _ body: (String) -> Void) {
        guard self.block.readableBytes > 0 else { return }
        self.block.withUnsafeReadableBytes { rawBytes in
            rawBytes.withMemoryRebound(to: UInt8.self) { typedBytes in
                guard let base = typedBytes.baseAddress else { return }
                let length = typedBytes.count
                QueryView.forEachValueInRange(
                    name: name, base: base, length: length, body: body
                )
            }
        }
    }

    /// All URL-decoded values for `name`, in insertion order.
    /// Convenience wrapper around `forEachValue(of:_:)` — allocates
    /// `[String]`.
    public func values(for name: String) -> [String] {
        var out: [String] = []
        forEachValue(of: name) { out.append($0) }
        return out
    }

    /// Number of key/value pairs in the query string (computed by
    /// walking the block). `O(blockLen)` — prefer `isEmpty` if you
    /// only need the "any?" signal.
    ///
    /// Consistent with `subscript` / `forEachValue`:
    ///   - Empty pairs (from `&&`, leading/trailing `&`) are skipped.
    ///   - Pairs with an empty key (`=value`) are skipped — they
    ///     cannot be looked up and are not counted.
    public var count: Int {
        guard self.block.readableBytes > 0 else { return 0 }
        return self.block.withUnsafeReadableBytes { rawBytes -> Int in
            rawBytes.withMemoryRebound(to: UInt8.self) { typedBytes -> Int in
                guard let base = typedBytes.baseAddress else { return 0 }
                return QueryView.countPairs(base, length: typedBytes.count)
            }
        }
    }

    /// `true` if the query string is empty / absent.
    @inlinable
    public var isEmpty: Bool { self.block.readableBytes == 0 }

    /// Clear the block. Used between keep-alive requests.
    @inlinable
    public mutating func removeAll() {
        self.block.clear()
    }

    // MARK: - Internal byte-walking primitives
    //
    // The query block is a sequence of `key=value` pairs separated by
    // `&` (0x26). Within a pair, the first `=` (0x3D) splits key from
    // value. A pair without `=` is treated as a key with empty value.
    //
    // All three walkers (`findBytes`, `forEachValueInRange`,
    // `countPairs`) share the same pair-splitting primitive:
    //   - `findSeparator` (SWAR-accelerated) → next `&` or end.
    //   - `findEquals`    (SWAR-accelerated) → first `=` in pair, or nil.
    // Key length is `eqOffset ?? pairLen`; a pair with keyLen == 0 is
    // malformed (`=value`) and skipped.

    /// Walk the block and count valid pairs (those with a non-empty
    /// key). Used by `count`.
    @usableFromInline
    @inline(__always)
    static func countPairs(_ block: UnsafePointer<UInt8>, length: Int) -> Int {
        var n = 0
        var pos = 0
        while pos < length {
            let pairEnd = findSeparator(block, from: pos, to: length)
            let pairLen = pairEnd - pos
            // Skip empty segments (e.g. `&&`, trailing `&`).
            guard pairLen > 0 else {
                pos = pairEnd + 1
                continue
            }
            // First `=` within the pair (if any) bounds the key.
            // `findEquals` returns an absolute byte offset into
            // `block`; subtract `pos` to get the key length.
            let eqPos = findEquals(block, from: pos, to: pairEnd)
            let keyLen = eqPos.map { $0 - pos } ?? pairLen
            // Count only pairs with a non-empty key (`=value` is skipped).
            if keyLen > 0 { n &+= 1 }
            if pairEnd == length { break }
            pos = pairEnd + 1
        }
        return n
    }

    /// Find the byte range `(start, len)` of the first value for
    /// `name` in the query block, still URL-encoded. Returns `nil`
    /// if the key is not present.
    @usableFromInline
    @inline(__always)
    static func findBytes(
        name: String,
        in block: UnsafePointer<UInt8>,
        length: Int
    ) -> (start: Int, len: Int)? {
        let needle = name.utf8
        let needleLen = needle.count
        var pos = 0
        while pos < length {
            let pairEnd = findSeparator(block, from: pos, to: length)
            let pairLen = pairEnd - pos
            // Skip empty segments (e.g. `&&` or trailing `&`).
            guard pairLen > 0 else {
                pos = pairEnd + 1
                continue
            }
            // `findEquals` returns an absolute byte offset into `block`.
            // Key length is its distance from `pos`, or the whole pair
            // when no `=` is present (`?foo` → key, empty value).
            let eqPos = findEquals(block, from: pos, to: pairEnd)
            let keyLen = eqPos.map { $0 - pos } ?? pairLen
            // A pair with an empty key (`=value`) is malformed and
            // ignored — no key can match an empty name.
            guard keyLen > 0 else {
                pos = pairEnd + 1
                continue
            }
            // Compare the key case-sensitively (RFC 3986: query is
            // not folded; matches Express/Flask/Echo behaviour).
            if keyLen == needleLen, keyMatches(
                block, at: pos, needle: needle, needleLen: needleLen
            ) {
                // Value = bytes after `=` (empty if `?foo`).
                let valueStart = eqPos.map { $0 + 1 } ?? pairEnd
                let valueLen = pairEnd - valueStart
                return (valueStart, valueLen)
            }
            pos = pairEnd + 1
        }
        return nil
    }

    /// Walk the block and invoke `body` for every value matching
    /// `name`. Used by `forEachValue(of:_:)`.
    @usableFromInline
    @inline(__always)
    static func forEachValueInRange(
        name: String,
        base: UnsafePointer<UInt8>,
        length: Int,
        body: (String) -> Void
    ) {
        let needle = name.utf8
        let needleLen = needle.count
        var pos = 0
        while pos < length {
            let pairEnd = findSeparator(base, from: pos, to: length)
            let pairLen = pairEnd - pos
            guard pairLen > 0 else {
                pos = pairEnd + 1
                continue
            }
            let eqPos = findEquals(base, from: pos, to: pairEnd)
            let keyLen = eqPos.map { $0 - pos } ?? pairLen
            guard keyLen > 0, keyLen == needleLen,
                  keyMatches(base, at: pos, needle: needle, needleLen: needleLen)
            else {
                pos = pairEnd + 1
                continue
            }
            let valueStart = eqPos.map { $0 + 1 } ?? pairEnd
            let valueLen = pairEnd - valueStart
            let value = decodeValue(
                UnsafeBufferPointer(start: base.advanced(by: valueStart), count: valueLen)
            )
            body(value)
            pos = pairEnd + 1
        }
    }

    /// Case-sensitive comparison of `keyLen` bytes at `block[pos]`
    /// against `needle`. Both spans must be exactly `keyLen` long.
    @usableFromInline
    @inline(__always)
    static func keyMatches(
        _ block: UnsafePointer<UInt8>,
        at pos: Int,
        needle: String.UTF8View,
        needleLen: Int
    ) -> Bool {
        var ni = needle.startIndex
        for i in 0..<needleLen {
            if block[pos + i] != needle[ni] { return false }
            ni = needle.index(after: ni)
        }
        return true
    }

    /// Find the next `&` separator starting at `from`, up to (but not
    /// including) `to`. Returns `to` if no separator is found.
    /// SWAR-accelerated via `SearchAlgorithm.findByte`.
    @usableFromInline
    @inline(__always)
    static func findSeparator(
        _ block: UnsafePointer<UInt8>,
        from start: Int,
        to end: Int
    ) -> Int {
        if let found = SearchAlgorithm.findByte(0x26, in: block, from: start, to: end) {
            return found
        }
        return end
    }

    /// Find the first `=` (0x3D) in `block[start..<end]`, or `nil`
    /// if the pair has no `=`. SWAR-accelerated via
    /// `SearchAlgorithm.findByte` — same primitive the parser uses
    /// for header-name detection (`isContentLength`, etc.).
    @usableFromInline
    @inline(__always)
    static func findEquals(
        _ block: UnsafePointer<UInt8>,
        from start: Int,
        to end: Int
    ) -> Int? {
        SearchAlgorithm.findByte(0x3D, in: block, from: start, to: end)
    }

    // MARK: - URL decoding

    /// URL-decode `bytes` into a `String`:
    ///   - `%XX` → byte 0xXX (validated: invalid hex → literal `%`).
    ///   - `+`   → space (0x20).
    ///   - Anything else → as-is.
    ///
    /// If the slice contains no `%` or `+`, the String is built
    /// directly from the slice (zero intermediate allocation). When
    /// decoding is needed, a small `[UInt8]` is filled first.
    ///
    /// The resulting bytes are interpreted as UTF-8 by
    /// `String(decoding:as:UTF8.self)`, so non-ASCII values
    /// (Cyrillic, CJK, emoji) work whether they arrived as raw bytes
    /// or as `%XX`-encoded UTF-8.
    @usableFromInline
    @inline(__always)
    static func decodeValue(_ bytes: UnsafeBufferPointer<UInt8>) -> String {
        // Fast path: scan for `%` or `+`. If neither is present,
        // build the String directly from the slice.
        var needsDecoding = false
        for i in 0..<bytes.count {
            let b = bytes[i]
            if b == 0x25 || b == 0x2B {  // `%` or `+`
                needsDecoding = true
                break
            }
        }
        if !needsDecoding {
            return String(decoding: bytes, as: UTF8.self)
        }

        // Slow path: decode into a fresh buffer.
        // The decoded result is always <= the encoded length, so we
        // can pre-allocate that capacity and avoid reallocation.
        var decoded: [UInt8] = []
        decoded.reserveCapacity(bytes.count)
        var i = 0
        let count = bytes.count
        let base = bytes.baseAddress!
        while i < count {
            let b = base[i]
            if b == 0x2B {  // `+`
                decoded.append(0x20)  // space
                i &+= 1
            } else if b == 0x25, i &+ 2 < count {  // `%XX`
                let hi = hexDigit(base[i &+ 1])
                let lo = hexDigit(base[i &+ 2])
                if let hi, let lo {
                    decoded.append(UInt8(hi << 4 | lo))
                    i &+= 3
                } else {
                    // Invalid hex — keep `%` literally.
                    decoded.append(b)
                    i &+= 1
                }
            } else {
                decoded.append(b)
                i &+= 1
            }
        }
        return String(decoding: decoded, as: UTF8.self)
    }

    /// Parse a single hex digit (case-insensitive) into 0…15, or
    /// `nil` if the byte is not a valid hex digit.
    @usableFromInline
    @inline(__always)
    static func hexDigit(_ b: UInt8) -> Int? {
        switch b {
        case 0x30...0x39:  // '0'...'9'
            return Int(b - 0x30)
        case 0x41...0x46:  // 'A'...'F'
            return Int(b - 0x41 + 10)
        case 0x61...0x66:  // 'a'...'f'
            return Int(b - 0x61 + 10)
        default:
            return nil
        }
    }
}
