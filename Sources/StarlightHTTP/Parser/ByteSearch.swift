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

    /// Convenience overload for `Span<UInt8>` (SE-0447) — bridges to
    /// the canonical `UnsafePointer` implementation via the span's
    /// `withUnsafeBufferPointer`. Zero allocation: the bridge is a
    /// stack-local `UnsafeBufferPointer` view over the span's storage.
    ///
    /// The `Span` overload is the preferred entry point for new code
    /// — `Span` is `~Copyable & ~Escapable`, so it carries the
    /// borrowing contract in its type.
    @inlinable
    @inline(__always)
    public static func findByte(
        _ needle: UInt8,
        in span: borrowing Span<UInt8>,
        from start: Int,
        to end: Int
    ) -> Int? {
        guard start < end else { return nil }
        return span.withUnsafeBufferPointer { ptr -> Int? in
            findByte(needle, in: ptr.baseAddress!, from: start, to: end)
        }
    }
}
