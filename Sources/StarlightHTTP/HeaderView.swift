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
//  the header section) into the per-request arena as **one contiguous
//  allocation**, then hands HeaderView a `(pointer, length)` pair
//  describing that block. HeaderView itself stores only that pair —
//  16 bytes inline, no heap allocation, no array, no ARC traffic.
//
//  When user code calls `headers[...]`, HeaderView walks the block
//  on-the-fly: it scans for CRLF, finds the colon separating name
//  from value, compares the name case-insensitively, and constructs
//  the value String on demand. This re-parse is O(block length),
//  which is the same work the parser already did — but it happens
//  only if the handler actually reads a header.
//
//  Handlers that don't read headers (the common case for hello-world
//  benchmarks, /health probes, static-file serving, and any endpoint
//  that only looks at the path) pay only the one-shot arena memcpy
//  for the header block — same as before HeaderView existed.
//
//  Net overhead on the hot path: one `setBlock(ptr, len)` call that
//  writes two fields, plus the arena allocation for the block (which
//  the parser was already doing per-header anyway, just now batched
//  into one allocation rather than N).
//
//===----------------------------------------------------------------------===//

/// Read-only view over the captured HTTP headers.
///
/// Backed by a single contiguous arena allocation holding every
/// header line. Subscript access scans the block on demand and
/// materializes the matched value as a `String`. Case-insensitive
/// on lookup (RFC 7230 §3.2).
public struct HeaderView: @unchecked Sendable {
    /// Pointer to the arena-backed header block. Valid until the
    /// owning `RequestContext` is reset.
    @usableFromInline internal var blockPtr: UnsafePointer<UInt8>?

    /// Length of the header block in bytes. Includes the terminating
    /// empty CRLF line, so the block can be re-parsed without special
    /// end-of-block logic.
    @usableFromInline internal var blockLen: Int

    @inlinable
    public init() {
        self.blockPtr = nil
        self.blockLen = 0
    }

    /// Record the arena-backed header block. Called once by the
    /// parser after it has copied the entire header section into the
    /// arena as a single contiguous allocation.
    @inlinable
    public mutating func setBlock(_ ptr: UnsafePointer<UInt8>, _ len: Int) {
        self.blockPtr = ptr
        self.blockLen = len
    }

    /// Look up the first value for `name`, case-insensitive. Returns
    /// `nil` if the header was not present in the request.
    ///
    /// - Complexity: O(blockLen) byte comparisons. The matched value
    ///   is materialized as a `String` on demand.
    public subscript(_ name: String) -> String? {
        guard let block = self.blockPtr else { return nil }
        return HeaderView.find(
            name: name, in: block, length: self.blockLen
        )
    }

    /// All values for `name`, in insertion order. Use for multi-valued
    /// headers like `Set-Cookie` (rare on requests, common on responses).
    public func values(for name: String) -> [String] {
        guard let block = self.blockPtr else { return [] }
        var out: [String] = []
        // Walk the block and collect every matching value.
        var pos = 0
        while pos < self.blockLen {
            // Find the end of the current line.
            guard let lineEnd = HeaderView.findByte(
                0x0A, in: block, from: pos, to: self.blockLen
            ) else { break }
            // Empty line (just CRLF or LF) → end of headers.
            let lineContentEnd = (lineEnd > pos && block[lineEnd - 1] == 0x0D)
                ? lineEnd - 1
                : lineEnd
            if lineContentEnd == pos { break }
            // Try to match the line against `name : value`.
            if let value = HeaderView.matchLine(
                block, lineStart: pos, lineContentEnd: lineContentEnd,
                needle: name
            ) {
                out.append(value)
            }
            pos = lineEnd + 1
        }
        return out
    }

    /// Number of captured headers (computed by walking the block).
    /// `O(blockLen)` — prefer `isEmpty` if you only need the "any?"
    /// signal.
    public var count: Int {
        guard let block = self.blockPtr else { return 0 }
        var n = 0
        var pos = 0
        while pos < self.blockLen {
            guard let lineEnd = HeaderView.findByte(
                0x0A, in: block, from: pos, to: self.blockLen
            ) else { break }
            let lineContentEnd = (lineEnd > pos && block[lineEnd - 1] == 0x0D)
                ? lineEnd - 1
                : lineEnd
            if lineContentEnd != pos { n &+= 1 }
            pos = lineEnd + 1
        }
        return n
    }

    /// `true` if the block is empty / unset.
    @inlinable
    public var isEmpty: Bool { self.blockLen == 0 }

    /// Clear the block reference. Used between keep-alive requests.
    @inlinable
    public mutating func removeAll() {
        self.blockPtr = nil
        self.blockLen = 0
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
            // Find end of current line.
            guard let lineEnd = findByte(0x0A, in: block, from: pos, to: length) else {
                return nil
            }
            let lineContentEnd = (lineEnd > pos && block[lineEnd - 1] == 0x0D)
                ? lineEnd - 1
                : lineEnd
            // Empty line → end of headers.
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
        let nl = needleLen ?? needle.utf8.count
        // Need at least: needle + ':' + value (1 char).
        guard lineContentEnd - lineStart >= nl + 2 else { return nil }
        // Compare `needle` byte-by-byte against the line, case-insensitively.
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
        // The byte after the name must be ':' (ignoring leading
        // whitespace is not standard for header *names* — RFC 7230
        // forbids whitespace between field-name and colon).
        guard block[li] == 0x3A else { return nil }
        var valueStart = li + 1
        // Skip optional leading whitespace in the value.
        while valueStart < lineContentEnd
                && (block[valueStart] == 0x20 || block[valueStart] == 0x09) {
            valueStart &+= 1
        }
        let valueLen = lineContentEnd - valueStart
        return String(decoding: UnsafeBufferPointer(
            start: block.advanced(by: valueStart), count: valueLen
        ), as: UTF8.self)
    }

    /// SWAR-accelerated single-byte search inside the block.
    @usableFromInline
    @inline(__always)
    static func findByte(
        _ needle: UInt8,
        in block: UnsafePointer<UInt8>,
        from start: Int,
        to end: Int
    ) -> Int? {
        // Scalar scan — the block is typically < 1 KB so SWAR's
        // setup cost is not amortized. (We re-use the parser's SWAR
        // helper when scanning the receive buffer; this is the
        // HeaderView-internal walker for subscript access.)
        var i = start
        while i < end {
            if block[i] == needle { return i }
            i &+= 1
        }
        return nil
    }
}
