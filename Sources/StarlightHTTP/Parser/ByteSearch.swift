//===----------------------------------------------------------------------===//
//
//  ByteSearch.swift
//  StarlightHTTP
//
//  SWAR-accelerated byte-search primitives used by the HTTP/1 parser
//  and HeaderView.
//
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Result of a multi-needle search: where the match was found, and which
/// of the needles matched.
public struct ByteMatch: Sendable, Equatable {
    public let index: Int
    public let needleIndex: Int

    @inlinable
    public init(index: Int, needleIndex: Int) {
        self.index = index
        self.needleIndex = needleIndex
    }
}

/// SWAR-accelerated byte-search primitives. Used by the HTTP/1 parser
/// (request-line / header-line scanning) and HeaderView (header-block
/// walking). All methods are zero-allocation and `@inline(__always)`.
public enum SearchAlgorithm {

    // MARK: - Single-byte search

    /// Find the first occurrence of `needle` in `pointer[start..<end]`.
    ///
    /// Uses the SWAR "byte-equals" trick (same as glibc's `memchr`):
    /// XOR a `UInt64` chunk with a broadcast pattern, then detect any
    /// zero byte via `(x &- 0x01...) & ~x & 0x80...`.
    ///
    /// - Returns: the index relative to `pointer`, or `nil` if not found.
    @inlinable
    @inline(__always)
    public static func findByte(
        _ needle: UInt8,
        in pointer: UnsafePointer<UInt8>,
        from start: Int,
        to end: Int
    ) -> Int? {
        guard start < end else { return nil }
        let pattern: UInt64 = UInt64(needle) &* 0x0101_0101_0101_0101
        var i = start

        while i + 8 <= end {
            var chunk: UInt64 = 0
            memcpy(&chunk, pointer.advanced(by: i), 8)
            let x = chunk ^ pattern
            let test = (x &- 0x0101_0101_0101_0101) & ~x & 0x8080_8080_8080_8080
            if test != 0 {
                return i + (test.trailingZeroBitCount / 8)
            }
            i &+= 8
        }

        while i < end {
            if pointer[i] == needle { return i }
            i &+= 1
        }
        return nil
    }

    /// Convenience overload for `UnsafeBufferPointer` — delegates to the
    /// canonical `UnsafePointer` implementation.
    @inlinable
    @inline(__always)
    public static func findByte(
        _ needle: UInt8,
        in bytes: UnsafeBufferPointer<UInt8>,
        from start: Int = 0,
        to end: Int? = nil
    ) -> Int? {
        let hi = end ?? bytes.count
        guard start < hi else { return nil }
        return findByte(needle, in: bytes.baseAddress!, from: start, to: hi)
    }

    // MARK: - Two-byte search

    /// Find the first occurrence of `a` OR `b`. Returns the index of
    /// the earlier match and which needle matched (0 for `a`, 1 for `b`).
    @inlinable
    @inline(__always)
    public static func findFirstOf2(
        _ a: UInt8,
        _ b: UInt8,
        in bytes: UnsafeBufferPointer<UInt8>,
        from start: Int = 0,
        to end: Int? = nil
    ) -> ByteMatch? {
        let hi = end ?? bytes.count
        guard start < hi else { return nil }

        if a == b {
            if let i = findByte(a, in: bytes, from: start, to: hi) {
                return ByteMatch(index: i, needleIndex: 0)
            }
            return nil
        }

        let base = bytes.baseAddress!
        let pa: UInt64 = UInt64(a) &* 0x0101_0101_0101_0101
        let pb: UInt64 = UInt64(b) &* 0x0101_0101_0101_0101
        var i = start

        while i + 8 <= hi {
            var chunk: UInt64 = 0
            memcpy(&chunk, base.advanced(by: i), 8)
            let xa = chunk ^ pa
            let xb = chunk ^ pb
            let ta = (xa &- 0x0101_0101_0101_0101) & ~xa & 0x8080_8080_8080_8080
            let tb = (xb &- 0x0101_0101_0101_0101) & ~xb & 0x8080_8080_8080_8080
            if ta != 0 || tb != 0 {
                let bitA = ta.trailingZeroBitCount
                let bitB = tb.trailingZeroBitCount
                if bitA < bitB {
                    return ByteMatch(index: i + bitA / 8, needleIndex: 0)
                } else {
                    return ByteMatch(index: i + bitB / 8, needleIndex: 1)
                }
            }
            i &+= 8
        }

        while i < hi {
            let v = base[i]
            if v == a { return ByteMatch(index: i, needleIndex: 0) }
            if v == b { return ByteMatch(index: i, needleIndex: 1) }
            i &+= 1
        }
        return nil
    }

    // MARK: - Multi-byte convenience

    @inlinable
    public static func findFirstOf(
        _ needles: (UInt8, UInt8),
        in bytes: UnsafeBufferPointer<UInt8>,
        from start: Int = 0,
        to end: Int? = nil
    ) -> ByteMatch? {
        findFirstOf2(needles.0, needles.1, in: bytes, from: start, to: end)
    }

    @inlinable
    public static func findFirstOf(
        _ needles: (UInt8, UInt8, UInt8),
        in bytes: UnsafeBufferPointer<UInt8>,
        from start: Int = 0,
        to end: Int? = nil
    ) -> ByteMatch? {
        if let m = findFirstOf2(needles.0, needles.1, in: bytes, from: start, to: end) {
            if let i = findByte(needles.2, in: bytes, from: start, to: m.index) {
                return ByteMatch(index: i, needleIndex: 2)
            }
            return m
        }
        if let i = findByte(needles.2, in: bytes, from: start, to: end) {
            return ByteMatch(index: i, needleIndex: 2)
        }
        return nil
    }
}
