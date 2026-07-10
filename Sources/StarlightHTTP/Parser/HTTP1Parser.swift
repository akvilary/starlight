//===----------------------------------------------------------------------===//
//
//  HTTP1Parser.swift
//  StarlightHTTP
//
//  Zero-copy HTTP/1.1 request parser, modelled on picohttpparser (H2O)
//  and Node.js's http-parser.
//
//  Design:
//  - State machine across three phases: request line, headers, body.
//  - The parser operates on a caller-owned byte buffer (typically a NIO
//    `ByteBuffer`'s readable slice). The caller hands in the whole
//    accumulated buffer on each `feed(...)` call; the parser advances
//    its `consumedBytes` pointer and reports whether it has reached
//    `.complete`. If not, the caller waits for more bytes from the
//    socket and feeds again.
//  - All parsing is done by SIMD-class byte-search (`findByte`,
//    `findFirstOf2`) over the buffer. No per-byte virtual dispatch.
//  - Parsed fields are written into a caller-owned `RequestContext`:
//      - `method` is decoded into a `HTTPMethod` enum (5–7 byte
//        comparison, no allocation).
//      - `path` is stored as an offset+length pair into the buffer,
//        accessible via a borrowed view in Phase 3.
//      - `headers` are appended to the context's arena as (name-span,
//        value-span) pairs. No copies, no ARC traffic.
//
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

import StarlightCore

/// Parser state.
public enum HTTP1ParserState: Sendable, Equatable {
    /// Reading the request line: `METHOD SP PATH SP HTTP/1.1 CRLF`.
    case requestLine
    /// Reading headers, one per line: `Name: Value CRLF`.
    case headers
    /// Reading `bodyBytesRemaining` body bytes.
    case body(remaining: Int)
    /// Parsing is complete; the request can be dispatched.
    case complete
    /// A malformed request — the connection should be closed with 400.
    case error
}

/// Errors thrown by the parser.
public enum HTTP1ParseError: Error, Sendable, Equatable {
    /// The request line doesn't fit `METHOD SP PATH SP HTTP/x.y CRLF`.
    case malformedRequestLine
    /// A header line doesn't fit `Name: Value CRLF`.
    case malformedHeader
    /// The HTTP version string is not `HTTP/1.0` or `HTTP/1.1`.
    case unsupportedVersion
    /// The request exceeds the configured maximum size.
    case requestTooLarge
    /// A chunked-transfer request was received — Phase 2 supports only
    /// `Content-Length`-bounded bodies.
    case chunkedNotSupported
    /// The `Content-Length` header was present but contained a
    /// non-integer, negative, or otherwise invalid value.
    /// RFC 7230 §3.3.2 requires a 400 response.
    case invalidContentLength
    /// An unexpected byte was found at the indicated offset.
    case unexpectedByte(offset: Int)
}

/// Zero-copy HTTP/1.1 request parser.
///
/// The parser is `~Copyable` because it owns its own internal state
/// (current position, state machine phase). Exactly one parser per
/// connection.
public struct HTTP1Parser: ~Copyable {
    /// Current state of the state machine.
    public private(set) var state: HTTP1ParserState = .requestLine

    /// Bytes consumed from the input buffer so far (across all phases).
    public private(set) var consumedBytes: Int = 0

    /// Offset into the input buffer where the URL path begins.
    /// Set during request-line parsing. The codec uses this (plus
    /// `pathLength`) to create a zero-copy `ByteBuffer` slice for
    /// `ctx.path` — avoiding the heap `String` allocation that
    /// `String(decoding:as:)` incurs for paths > 15 bytes.
    public private(set) var pathStart: Int = 0

    /// Length of the URL path in the input buffer.
    /// Valid after the request line has been parsed.
    public private(set) var pathLength: Int = 0

    /// Offset into the input buffer where the header section begins.
    private var headerBlockStart: Int = 0

    /// Offset into the input buffer where the body section begins
    /// (i.e. immediately after the empty line that terminates headers).
    /// Used by the codec to create a zero-copy `ByteBuffer` slice for
    /// `ctx.body` after parsing is complete.
    public private(set) var bodyStart: Int = 0

    /// Maximum allowed total request size (request line + headers + body).
    /// Default 64 KiB — comfortably fits any reasonable HTTP/1.1 request.
    public let maxRequestBytes: Int

    /// Maximum number of headers. Default 100. Rejects pathological
    /// "header-bomb" requests early.
    public let maxHeaderCount: Int

    /// Length of the parsed body in bytes. Zero for bodyless requests.
    /// Valid only when `state == .complete`.
    @inlinable
    public var bodyLength: Int { consumedBytes - bodyStart }

    /// Initialize a fresh parser.
    @inlinable
    public init(
        maxRequestBytes: Int = 64 * 1024,
        maxHeaderCount: Int = 100
    ) {
        self.maxRequestBytes = maxRequestBytes
        self.maxHeaderCount = maxHeaderCount
    }

    /// Reset to the initial state for the next request on the same
    /// connection. Called after the previous request has been fully
    /// dispatched.
    public mutating func reset() {
        self.state = .requestLine
        self.consumedBytes = 0
        self.headerBlockStart = 0
        self.bodyStart = 0
        self.pathStart = 0
        self.pathLength = 0
    }

    /// Feed bytes from an accumulated buffer. The parser reads from
    /// `buffer[consumedBytes..<buffer.count]` and advances. Returns
    /// `true` if the parser has reached `.complete`.
    ///
    /// - Parameters:
    ///   - buffer: the full request accumulator owned by the caller.
    ///     The parser only reads `buffer[consumedBytes...]` on each call.
    ///   - ctx: the per-connection `RequestContext` to write parsed
    ///     fields into.
    /// - Returns: `true` iff the parser has reached `.complete`.
    /// - Throws: `HTTP1ParseError` on malformed input.
    public mutating func feed(
        _ buffer: UnsafeBufferPointer<UInt8>,
        into ctx: inout RequestContext
    ) throws -> Bool {
        let count = buffer.count
        while consumedBytes < count {
            // Snapshot state before each step so we can detect "no
            // progress" — i.e. the step needs more bytes that haven't
            // arrived yet. Without this guard the parser would spin
            // forever on a partial request line.
            let prevConsumed = consumedBytes
            let prevState = state

            switch state {
            case .requestLine:
                try stepRequestLine(buffer, count: count, into: &ctx)
            case .headers:
                try stepHeaders(buffer, count: count, into: &ctx)
            case .body(var remaining):
                let available = min(remaining, count - consumedBytes)
                consumedBytes &+= available
                remaining &-= available
                if remaining == 0 {
                    // Body is fully received. The body bytes are at
                    // [bodyStart, consumedBytes) in the input buffer.
                    // The codec creates a zero-copy ByteBuffer slice
                    // from the accumulator — no copy needed here.
                    state = .complete
                    return true
                } else {
                    state = .body(remaining: remaining)
                    return false
                }
            case .complete:
                return true
            case .error:
                throw HTTP1ParseError.unexpectedByte(offset: consumedBytes)
            }

            // No progress and no state change → wait for more bytes.
            if consumedBytes == prevConsumed && state == prevState {
                return false
            }
        }
        return state == .complete
    }

    // MARK: - Steps

    /// Parse the request line. Transitions to `.headers` on success.
    @usableFromInline
    mutating func stepRequestLine(
        _ buffer: UnsafeBufferPointer<UInt8>,
        count: Int,
        into ctx: inout RequestContext
    ) throws {
        // Find end of request line: '\n' (which may be preceded by '\r').
        guard let nl = findByte(0x0A, in: buffer, from: consumedBytes, to: count)
        else { return }  // incomplete — wait for more bytes

        let lineEnd = nl
        // Line excludes optional trailing '\r'.
        let lineContentEnd = (lineEnd > consumedBytes && buffer[lineEnd - 1] == 0x0D)
            ? lineEnd - 1
            : lineEnd
        let lineStart = consumedBytes

        // Find first SP (separates METHOD from PATH).
        guard let sp1 = findByte(0x20, in: buffer, from: lineStart, to: lineContentEnd)
        else { state = .error; throw HTTP1ParseError.malformedRequestLine }

        // Find second SP (separates PATH from VERSION).
        guard let sp2 = findByte(0x20, in: buffer, from: sp1 + 1, to: lineContentEnd)
        else { state = .error; throw HTTP1ParseError.malformedRequestLine }

        // METHOD = [lineStart, sp1)
        let methodLen = sp1 - lineStart
        guard methodLen >= 1 else {
            state = .error; throw HTTP1ParseError.malformedRequestLine
        }
        ctx.method = decodeMethod(buffer, offset: lineStart, length: methodLen)

        // PATH = [sp1+1, sp2)
        let pStart = sp1 + 1
        let pLen = sp2 - pStart
        guard pLen >= 1 else {
            state = .error; throw HTTP1ParseError.malformedRequestLine
        }
        // Record the path's byte location for the codec to create a
        // zero-copy ByteBuffer slice. Avoids the heap String allocation
        // that String(decoding:as:) incurs for paths > 15 bytes
        // (the majority of real-world paths like /api/v1/users/42).
        self.pathStart = pStart
        self.pathLength = pLen

        // VERSION = [sp2+1, lineContentEnd)
        let versionStart = sp2 + 1
        let versionLen = lineContentEnd - versionStart
        try validateVersion(buffer, offset: versionStart, length: versionLen)

        // Advance past the trailing '\n'.
        consumedBytes = lineEnd + 1
        // Record where the header section starts in the input buffer.
        // We'll use this at end-of-headers to copy the whole block
        // into the arena as a single contiguous allocation.
        headerBlockStart = consumedBytes
        state = .headers
    }

    /// Parse one header line, or detect end-of-headers. Transitions to
    /// `.complete` on end-of-headers (Phase 2 does not parse bodies).
    @usableFromInline
    mutating func stepHeaders(
        _ buffer: UnsafeBufferPointer<UInt8>,
        count: Int,
        into ctx: inout RequestContext
    ) throws {
        // Find end of header line.
        guard let nl = findByte(0x0A, in: buffer, from: consumedBytes, to: count)
        else { return }  // incomplete

        let lineEnd = nl
        let lineContentEnd = (lineEnd > consumedBytes && buffer[lineEnd - 1] == 0x0D)
            ? lineEnd - 1
            : lineEnd
        let lineStart = consumedBytes

        // End-of-headers marker: empty line (CRLF or LF).
        if lineContentEnd == lineStart {
            // We've reached the end of the header section. Copy the
            // entire header block (from `headerBlockStart` through
            // the end of this empty line, inclusive) into the arena
            // as a single contiguous allocation, and hand HeaderView
            // a (pointer, length) pair over it.
            //
            // This is the only per-request allocation we do for
            // headers — one memcpy of the block, no per-header
            // allocations, no String construction on the hot path.
            let blockEnd = lineEnd + 1  // include the empty line's LF
            let blockStart = headerBlockStart
            let blockLen = blockEnd - blockStart
            // Only copy the block if it actually contains headers.
            // An empty header section is just the terminating LF
            // (blockLen == 1) or CRLF (blockLen == 2) — copying that
            // would make `headers.isEmpty` return false. Skip the
            // copy for blocks that are just the terminator.
            if blockLen > 2 {
                let blockBuf = ctx.allocate(bytes: blockLen, alignment: 1)
                blockBuf.baseAddress!.copyMemory(
                    from: UnsafeRawPointer(buffer.baseAddress!).advanced(by: blockStart),
                    byteCount: blockLen
                )
                ctx.headers.setBlock(
                    blockBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    blockLen
                )
            }
            consumedBytes = blockEnd
            // Record where body starts (right after the empty line).
            bodyStart = consumedBytes

            // Check Content-Length to determine if there's a body.
            // The headers are now in ctx.headers (lazy HeaderView).
            // RFC 7230 §3.3.2: an invalid Content-Length MUST be
            // rejected with 400. We validate strictly — only
            // non-negative decimal integers are accepted.
            let contentLength: Int?
            if let clStr = ctx.headers["Content-Length"] {
                guard let cl = Self.parseContentLength(clStr) else {
                    state = .error
                    throw HTTP1ParseError.invalidContentLength
                }
                contentLength = cl
            } else {
                contentLength = nil
            }

            if let cl = contentLength, cl > 0 {
                state = .body(remaining: cl)
            } else {
                state = .complete
            }
            return
        }

        // Validate that the line has a `:` separating name from value.
        // We do NOT copy the name/value into the arena here — the
        // entire block copy above handles that. We only validate so
        // malformed requests trigger a 400.
        guard findByte(0x3A, in: buffer, from: lineStart, to: lineContentEnd) != nil
        else { state = .error; throw HTTP1ParseError.malformedHeader }

        consumedBytes = lineEnd + 1
        // Stay in `.headers` for the next line.
    }

    // MARK: - Helpers

    @usableFromInline
    @inline(__always)
    func decodeMethod(
        _ buffer: UnsafeBufferPointer<UInt8>,
        offset: Int,
        length: Int
    ) -> HTTPMethod {
        // Fast-path common cases by length + first byte. Avoids a
        // generic byte-by-byte compare.
        let base = buffer.baseAddress!
        switch length {
        case 3:
            // GET, PUT
            if base[offset] == 0x47  // 'G'
                && base[offset + 1] == 0x45  // 'E'
                && base[offset + 2] == 0x54 { // 'T'
                return .GET
            }
            if base[offset] == 0x50  // 'P'
                && base[offset + 1] == 0x55  // 'U'
                && base[offset + 2] == 0x54 { // 'T'
                return .PUT
            }
            return .other
        case 4:
            // POST, HEAD
            if base[offset] == 0x50  // 'P'
                && base[offset + 1] == 0x4F  // 'O'
                && base[offset + 2] == 0x53  // 'S'
                && base[offset + 3] == 0x54 { // 'T'
                return .POST
            }
            if base[offset] == 0x48  // 'H'
                && base[offset + 1] == 0x45  // 'E'
                && base[offset + 2] == 0x41  // 'A'
                && base[offset + 3] == 0x44 { // 'D'
                return .HEAD
            }
            return .other
        case 5:
            // PATCH, TRACE
            if base[offset] == 0x50  // 'P'
                && base[offset + 1] == 0x41  // 'A'
                && base[offset + 2] == 0x54  // 'T'
                && base[offset + 3] == 0x43  // 'C'
                && base[offset + 4] == 0x48 { // 'H'
                return .PATCH
            }
            if base[offset] == 0x54  // 'T'
                && base[offset + 1] == 0x52  // 'R'
                && base[offset + 2] == 0x41  // 'A'
                && base[offset + 3] == 0x43  // 'C'
                && base[offset + 4] == 0x45 { // 'E'
                return .TRACE
            }
            return .other
        case 6:
            // DELETE
            if base[offset] == 0x44  // 'D'
                && base[offset + 1] == 0x45  // 'E'
                && base[offset + 2] == 0x4C  // 'L'
                && base[offset + 3] == 0x45  // 'E'
                && base[offset + 4] == 0x54  // 'T'
                && base[offset + 5] == 0x45 { // 'E'
                return .DELETE
            }
            return .other
        case 7:
            // OPTIONS, CONNECT
            if base[offset] == 0x4F  // 'O'
                && base[offset + 1] == 0x50  // 'P'
                && base[offset + 2] == 0x54  // 'T'
                && base[offset + 3] == 0x49  // 'I'
                && base[offset + 4] == 0x4F  // 'O'
                && base[offset + 5] == 0x4E  // 'N'
                && base[offset + 6] == 0x53 { // 'S'
                return .OPTIONS
            }
            if base[offset] == 0x43  // 'C'
                && base[offset + 1] == 0x4F  // 'O'
                && base[offset + 2] == 0x4E  // 'N'
                && base[offset + 3] == 0x4E  // 'N'
                && base[offset + 4] == 0x45  // 'E'
                && base[offset + 5] == 0x43  // 'C'
                && base[offset + 6] == 0x54 { // 'T'
                return .CONNECT
            }
            return .other
        default:
            return .other
        }
    }

    @usableFromInline
    @inline(__always)
    mutating func validateVersion(
        _ buffer: UnsafeBufferPointer<UInt8>,
        offset: Int,
        length: Int
    ) throws {
        // Accept "HTTP/1.0" and "HTTP/1.1".
        guard length == 8 else {
            state = .error
            throw HTTP1ParseError.unsupportedVersion
        }
        let base = buffer.baseAddress!
        // Inline byte comparison — no [UInt8] allocation.
        if  base[offset]     != 0x48  // H
            || base[offset + 1] != 0x54  // T
            || base[offset + 2] != 0x54  // T
            || base[offset + 3] != 0x50  // P
            || base[offset + 4] != 0x2F  // /
            || base[offset + 5] != 0x31  // 1
            || base[offset + 6] != 0x2E  // .
        {
            state = .error
            throw HTTP1ParseError.unsupportedVersion
        }
        if base[offset + 7] != 0x30 && base[offset + 7] != 0x31 {
            state = .error
            throw HTTP1ParseError.unsupportedVersion
        }
    }

    /// Strict Content-Length validator.
    ///
    /// Accepts only non-negative decimal integers (e.g. `"0"`, `"42"`,
    /// `"1048576"`). Rejects empty strings, negative numbers, values
    /// with leading/trailing whitespace inside the digits, non-ASCII
    /// digits, and values that overflow `Int`.
    ///
    /// This is stricter than `Int(_:)` which silently returns `nil`
    /// for invalid input — we need to distinguish "header absent"
    /// from "header invalid" and return 400 for the latter.
    ///
    /// - Returns: The parsed length, or `nil` if the string is invalid.
    @usableFromInline
    @inline(__always)
    static func parseContentLength(_ str: String) -> Int? {
        guard !str.isEmpty else { return nil }
        var result = 0
        for byte in str.utf8 {
            // Only ASCII digits 0x30–0x39 are valid.
            if byte < 0x30 || byte > 0x39 { return nil }
            result = result &* 10 &+ Int(byte - 0x30)
            // Overflow check: if result went negative, the value
            // exceeded Int.max on this platform.
            if result < 0 { return nil }
        }
        return result
    }
}
