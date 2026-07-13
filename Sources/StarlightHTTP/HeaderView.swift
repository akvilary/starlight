//===----------------------------------------------------------------------===//
//
//  HeaderView.swift
//  StarlightHTTP
//
//  Read-only view over the HTTP request headers captured by the
//  parser. Zero per-request overhead in the common case where the
//  handler does not read any headers.
//
//  ─── Design ─────────────────────────────────────────────────────────────
//
//  The parser copies the *entire* header block (every header line,
//  joined by CRLF, ending with the empty CRLF line that terminates
//  the header section) into a reusable `ByteBuffer` via
//  `copyBlock(...)`, then HeaderView walks that block on demand: it
//  scans for CRLF, finds the colon separating name from value,
//  compares the name case-insensitively, and constructs the value
//  String on demand.
//
//  Handlers that don't read headers (the common case for hello-world
//  benchmarks, /health probes, static-file serving, and any endpoint
//  that only looks at the path) pay only the one-shot `ByteBuffer`
//  write for the header block — same as before, minus the arena.
//
//  Because the backing store is a COW `ByteBuffer` (not a raw arena
//  pointer), HeaderView is naturally `Sendable` without
//  `@unchecked` — copying a HeaderView bumps the storage refcount,
//  and the copy remains valid even after `removeAll()` on the
//  original (COW keeps the old storage alive).
//
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

import NIOCore

/// Read-only view over the captured HTTP headers.
///
/// Backed by a single contiguous `ByteBuffer` holding every header
/// line. Subscript access scans the block on demand and materializes
/// the matched value as a `String`. Case-insensitive on lookup
/// (RFC 7230 §3.2).
public struct HeaderView: Sendable {
    /// The header block data. Reusable across keep-alive requests —
    /// `copyBlock` clears and refills it, and `removeAll` resets it.
    @usableFromInline internal var block: ByteBuffer

    @inlinable
    public init() {
        self.block = ByteBufferAllocator().buffer(capacity: 0)
    }

    /// Copy `count` bytes from `buffer` (starting at `offset`) into
    /// the header block. Called once by the parser after it has
    /// identified the entire header section. The ByteBuffer is
    /// cleared first and then written — its storage grows as needed
    /// and is reused across keep-alive requests (no per-request
    /// allocation after the first request on a connection).
    @inlinable
    internal mutating func copyBlock(
        from buffer: UnsafeBufferPointer<UInt8>,
        offset: Int,
        count: Int
    ) {
        self.block.clear()
        self.block.writeBytes(UnsafeBufferPointer(
            start: buffer.baseAddress!.advanced(by: offset),
            count: count
        ))
    }

    // MARK: - Public lookup API

    /// Look up the first value for `name`, case-insensitive. Returns
    /// `nil` if the header was not present in the request.
    ///
    /// - Complexity: O(blockLen) byte comparisons. The matched value
    ///   is materialized as a `String` on demand.
    public subscript(_ name: String) -> String? {
        guard self.block.readableBytes > 0 else { return nil }
        return self.block.withUnsafeReadableBytes { rawBytes -> String? in
            rawBytes.withMemoryRebound(to: UInt8.self) { typedBytes -> String? in
                guard let base = typedBytes.baseAddress else { return nil }
                return HeaderView.find(
                    name: name, in: base, length: typedBytes.count
                )
            }
        }
    }

    /// Zero-copy header lookup. Returns the value as a byte buffer
    /// pointing directly into the header block — no `String`
    /// allocation. Use this in performance-critical handlers that
    /// need to inspect header values without paying for String
    /// construction.
    ///
    /// The returned pointer is valid until the next `removeAll()` or
    /// `copyBlock(...)` call.
    ///
    /// - Complexity: O(blockLen) byte comparisons.
    public func bytes(for name: String) -> UnsafeBufferPointer<UInt8>? {
        guard self.block.readableBytes > 0 else { return nil }
        return self.block.withUnsafeReadableBytes { rawBytes -> UnsafeBufferPointer<UInt8>? in
            rawBytes.withMemoryRebound(to: UInt8.self) { typedBytes -> UnsafeBufferPointer<UInt8>? in
                guard let base = typedBytes.baseAddress else { return nil }
                guard let (start, len) = HeaderView.findBytes(
                    name: name, in: base, length: typedBytes.count
                ) else { return nil }
                return UnsafeBufferPointer(start: base.advanced(by: start), count: len)
            }
        }
    }

    /// Case-insensitive comparison of a header value against an
    /// expected ASCII string, without allocating a `String` for the
    /// header value. Returns `true` if the header exists and matches.
    public func value(_ name: String, equals expected: String) -> Bool {
        guard self.block.readableBytes > 0 else { return false }
        return self.block.withUnsafeReadableBytes { rawBytes -> Bool in
            rawBytes.withMemoryRebound(to: UInt8.self) { typedBytes -> Bool in
                guard let base = typedBytes.baseAddress else { return false }
                guard let (start, len) = HeaderView.findBytes(
                    name: name, in: base, length: typedBytes.count
                ) else { return false }
                let expectedBytes = expected.utf8
                guard expectedBytes.count == len else { return false }
                var ei = expectedBytes.startIndex
                for i in 0..<len {
                    let hb = base[start + i]
                    let eb = expectedBytes[ei]
                    if hb == eb {
                        ei = expectedBytes.index(after: ei)
                        continue
                    }
                    let hbFold = (hb >= 0x41 && hb <= 0x5A) ? hb + 0x20 : hb
                    let ebFold = (eb >= 0x41 && eb <= 0x5A) ? eb + 0x20 : eb
                    if hbFold != ebFold { return false }
                    ei = expectedBytes.index(after: ei)
                }
                return true
            }
        }
    }

    /// All values for `name`, in insertion order. Use for multi-valued
    /// headers like `Set-Cookie` (rare on requests, common on responses).
    public func values(for name: String) -> [String] {
        guard self.block.readableBytes > 0 else { return [] }
        return self.block.withUnsafeReadableBytes { rawBytes -> [String] in
            rawBytes.withMemoryRebound(to: UInt8.self) { typedBytes -> [String] in
                guard let base = typedBytes.baseAddress else { return [] }
                let length = typedBytes.count
                var out: [String] = []
                var pos = 0
                while pos < length {
                    guard let lineEnd = HeaderView.findByte(
                        0x0A, in: base, from: pos, to: length
                    ) else { break }
                    let lineContentEnd = (lineEnd > pos && base[lineEnd - 1] == 0x0D)
                        ? lineEnd - 1
                        : lineEnd
                    if lineContentEnd == pos { break }
                    if let value = HeaderView.matchLine(
                        base, lineStart: pos, lineContentEnd: lineContentEnd,
                        needle: name
                    ) {
                        out.append(value)
                    }
                    pos = lineEnd + 1
                }
                return out
            }
        }
    }

    /// Number of captured headers (computed by walking the block).
    /// `O(blockLen)` — prefer `isEmpty` if you only need the "any?"
    /// signal.
    public var count: Int {
        guard self.block.readableBytes > 0 else { return 0 }
        return self.block.withUnsafeReadableBytes { rawBytes -> Int in
            rawBytes.withMemoryRebound(to: UInt8.self) { typedBytes -> Int in
                guard let base = typedBytes.baseAddress else { return 0 }
                let length = typedBytes.count
                var n = 0
                var pos = 0
                while pos < length {
                    guard let lineEnd = HeaderView.findByte(
                        0x0A, in: base, from: pos, to: length
                    ) else { break }
                    let lineContentEnd = (lineEnd > pos && base[lineEnd - 1] == 0x0D)
                        ? lineEnd - 1
                        : lineEnd
                    if lineContentEnd != pos { n &+= 1 }
                    pos = lineEnd + 1
                }
                return n
            }
        }
    }

    /// `true` if the block is empty / unset.
    @inlinable
    public var isEmpty: Bool { self.block.readableBytes == 0 }

    /// Clear the block. Used between keep-alive requests.
    @inlinable
    public mutating func removeAll() {
        self.block.clear()
    }

    // MARK: - Internal byte-walking primitives

    /// Find the first value of `name` in the header block.
    @usableFromInline
    @inline(__always)
    static func find(
        name: String,
        in block: UnsafePointer<UInt8>,
        length: Int
    ) -> String? {
        let needleLen = name.utf8.count
        var pos = 0
        while pos < length {
            guard let lineEnd = findByte(0x0A, in: block, from: pos, to: length) else {
                return nil
            }
            let lineContentEnd = (lineEnd > pos && block[lineEnd - 1] == 0x0D)
                ? lineEnd - 1
                : lineEnd
            if lineContentEnd == pos { return nil }
            if let value = matchLine(
                block, lineStart: pos, lineContentEnd: lineContentEnd,
                needle: name, needleLen: needleLen
            ) {
                return value
            }
            pos = lineEnd + 1
        }
        return nil
    }

    /// Find the first value of `name` in the header block, returning
    /// the byte range `(start, length)` into `block` without creating
    /// a `String`. Zero-allocation lookup.
    @usableFromInline
    @inline(__always)
    static func findBytes(
        name: String,
        in block: UnsafePointer<UInt8>,
        length: Int
    ) -> (start: Int, len: Int)? {
        let needleLen = name.utf8.count
        var pos = 0
        while pos < length {
            guard let lineEnd = findByte(0x0A, in: block, from: pos, to: length) else {
                return nil
            }
            let lineContentEnd = (lineEnd > pos && block[lineEnd - 1] == 0x0D)
                ? lineEnd - 1
                : lineEnd
            if lineContentEnd == pos { return nil }
            if let range = matchLineRange(
                block, lineStart: pos, lineContentEnd: lineContentEnd,
                needle: name, needleLen: needleLen
            ) {
                return range
            }
            pos = lineEnd + 1
        }
        return nil
    }

    /// Try to match a single header line against `needle`. Returns
    /// the value String if `lineStart..<lineContentEnd` parses as
    /// `needle ':' value` (case-insensitive on `needle`).
    @usableFromInline
    @inline(__always)
    static func matchLine(
        _ block: UnsafePointer<UInt8>,
        lineStart: Int,
        lineContentEnd: Int,
        needle: String,
        needleLen: Int? = nil
    ) -> String? {
        guard let range = matchLineRange(
            block, lineStart: lineStart, lineContentEnd: lineContentEnd,
            needle: needle, needleLen: needleLen
        ) else { return nil }
        return String(decoding: UnsafeBufferPointer(
            start: block.advanced(by: range.start), count: range.len
        ), as: UTF8.self)
    }

    /// Match a header line and return the value's byte range without
    /// creating a String. Shared core of `matchLine` (String-returning)
    /// and `findBytes` (zero-copy).
    @usableFromInline
    @inline(__always)
    static func matchLineRange(
        _ block: UnsafePointer<UInt8>,
        lineStart: Int,
        lineContentEnd: Int,
        needle: String,
        needleLen: Int? = nil
    ) -> (start: Int, len: Int)? {
        let nl = needleLen ?? needle.utf8.count
        guard lineContentEnd - lineStart >= nl + 1 else { return nil }
        var ni = needle.utf8.startIndex
        var li = lineStart
        var matched = true
        for _ in 0..<nl {
            let lb = block[li]
            let rb = needle.utf8[ni]
            if lb == rb {
                li &+= 1
                ni = needle.utf8.index(after: ni)
                continue
            }
            let lbFold = (lb >= 0x41 && lb <= 0x5A) ? lb + 0x20 : lb
            let rbFold = (rb >= 0x41 && rb <= 0x5A) ? rb + 0x20 : rb
            if lbFold != rbFold { matched = false; break }
            li &+= 1
            ni = needle.utf8.index(after: ni)
        }
        if !matched { return nil }
        guard block[li] == 0x3A else { return nil }
        var valueStart = li + 1
        while valueStart < lineContentEnd
                && (block[valueStart] == 0x20 || block[valueStart] == 0x09) {
            valueStart &+= 1
        }
        var valueEnd = lineContentEnd
        while valueEnd > valueStart
                && (block[valueEnd - 1] == 0x20 || block[valueEnd - 1] == 0x09) {
            valueEnd &-= 1
        }
        let valueLen = valueEnd - valueStart
        return (valueStart, valueLen)
    }

    /// Single-byte search inside the header block.
    /// Delegates to `SearchAlgorithm.findByte` (SWAR).
    @usableFromInline
    @inline(__always)
    static func findByte(
        _ needle: UInt8,
        in block: UnsafePointer<UInt8>,
        from start: Int,
        to end: Int
    ) -> Int? {
        SearchAlgorithm.findByte(needle, in: block, from: start, to: end)
    }
}
