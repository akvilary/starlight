//===----------------------------------------------------------------------===//
//
//  H1Conn.swift
//  StarlightServer
//
//  HTTP/1.1 connection driver — actor with state machine.
//
//  Replaces the buffer-everything `H1Decoder` with a streaming model:
//  `decodeHead()` parses only request headers, the body is pulled
//  lazily via `nextBodyChunk()`. Mirrors hyper's `Conn` state machine
//  (Reading::Init / Continue / Body / KeepAlive / Closed) adapted to
//  Swift's actor + async/await concurrency model.
//
//  Thread-safety: the actor pins itself to the connection's
//  `PollEventLoop` via `unownedExecutor`. All mutable state is
//  actor-isolated — no `@unchecked Sendable`. Cross-actor calls
//  from the same executor (the normal case for `driveConnection`)
//  execute inline through `isSameExclusiveExecutionContext`.
//
//  Lifetime: one `H1Conn` per TCP connection, amortised across all
//  keep-alive requests on that connection. `generation` increments
//  on every `decodeHead()` so stale body reads (from a handler that
//  escaped its `Request`) throw `BodyError.connectionAdvanced`
//  instead of corrupting the next request.
//
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#endif

import Foundation
import HTTP
import HTTPCodec
import Pulsar

/// Errors thrown by `H1Conn` during head parsing and body framing.
///
/// All smuggling-related rejections from the legacy `H1Decoder` are
/// preserved here — these are the regression targets covered by the
/// integration tests A17-A28 (bare CR/LF, CL+TE conflict, missing
/// Host, malformed chunk size, etc.).
public enum H1ConnError: Error, Sendable, Equatable {
    /// The request line doesn't fit `METHOD SP TARGET SP HTTP/x.y CRLF`.
    case malformedRequestLine
    /// A header line doesn't fit `Name: Value CRLF`.
    case malformedHeader(line: Int)
    /// The HTTP version string is not `HTTP/1.0` or `HTTP/1.1`.
    case unsupportedVersion(String)
    /// The request header block exceeds `maxHeaderBytes`.
    case requestTooLarge
    /// The `Content-Length` header was present but contained a
    /// non-integer, negative, or otherwise invalid value.
    case invalidContentLength
    /// Multiple `Content-Length` headers with conflicting values —
    /// potential HTTP smuggling (RFC 9112 §6.3.6).
    case conflictingContentLength
    /// Too many headers (> `maxHeaderCount`). Header-bomb defence.
    case tooManyHeaders
    /// An empty header name was encountered (RFC 9112 §5.1).
    case emptyHeaderName
    /// A `Transfer-Encoding: chunked` request body was malformed.
    case malformedChunkSize
    case malformedChunkData
    /// A header value contained a bare CR (0x0D) or LF (0x0A) that
    /// is not part of a CRLF pair (RFC 9112 §5.1). Header-injection
    /// / request-smuggling guard.
    case bareCrLfInHeader(line: Int)
    /// An HTTP/1.1 request without a `Host` header (RFC 9112 §3.2).
    case missingHost
    /// Both `Content-Length` and `Transfer-Encoding: chunked` were
    /// present — reject to defeat CL.TE / TE.CL smuggling.
    case conflictingFraming
    /// I/O error during read (timeout, EBADF, etc.).
    case ioError
}

/// One parsed request head + metadata needed by the dispatcher.
public struct DecodedHead: Sendable {
    /// The parsed request. Body is `.empty` if there is no body, or
    /// `.pull(...)` set up by the caller after `decodeHead` returns.
    public let request: Request
    /// Generation counter at the time of decode — pass back to
    /// `nextBodyChunk(forGeneration:)` to detect stale body reads.
    public let generation: UInt64
    /// Keep-alive decision computed from the request's Connection
    /// header **before** hop-by-hop stripping (fixes P0-3: the
    /// legacy code stripped Connection first and could never read
    /// it back).
    public let keepAlive: Bool
    /// Whether the request has a body (CL > 0 or chunked TE).
    public let hasBody: Bool
    /// Whether `Expect: 100-continue` was present and a 100 Continue
    /// interim response should be sent before reading the body.
    public let expects100Continue: Bool

    @inlinable
    public init(
        request: Request,
        generation: UInt64,
        keepAlive: Bool,
        hasBody: Bool,
        expects100Continue: Bool
    ) {
        self.request = request
        self.generation = generation
        self.keepAlive = keepAlive
        self.hasBody = hasBody
        self.expects100Continue = expects100Continue
    }
}

// MARK: - H1Conn actor

/// HTTP/1.1 connection driver — actor with state machine.
///
/// One instance per TCP connection. `decodeHead()` parses request
/// headers and sets up body framing; `nextBodyChunk(forGeneration:)`
/// pulls body bytes lazily from the underlying `PollEventLoop`.
///
/// All mutable state is actor-isolated. The actor's executor is the
/// connection's `PollEventLoop` (via `unownedExecutor`), so calls
/// from `driveConnection` (which runs on the same eventLoop) execute
/// inline — zero hop overhead on the hot path.
public actor H1Conn {

    // MARK: - Immutable configuration (nonisolated)

    public nonisolated let eventLoop: PollEventLoop
    public nonisolated let fd: CInt
    public nonisolated let channelId: UInt32
    public nonisolated let maxHeaderBytes: Int
    public nonisolated let maxBodyBytes: Int
    public nonisolated let maxHeaderCount: Int
    public nonisolated let readTimeout: Duration

    /// Pin this actor to the connection's eventLoop so all method
    /// calls execute on the loop thread. Combined with
    /// `isSameExclusiveExecutionContext` this gives zero-hop inline
    /// execution for the `driveConnection` → `H1Conn` calls.
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        eventLoop.asUnownedSerialExecutor()
    }

    // MARK: - Mutable state (actor-isolated)

    /// Persistent read buffer — bytes from `eventLoop.read` accumulate
    /// here, parsed headers and body chunks are consumed via `readPos`.
    var buffer: [UInt8] = []
    /// Consumed position — bytes before `readPos` are no longer needed.
    /// Compacted periodically to avoid unbounded growth (see
    /// `maybeCompact()`).
    var readPos: Int = 0

    /// Connection-level state machine — mirrors hyper's `Reading` enum.
    var state: State = .readingHead

    /// Incremented on every successful `decodeHead()`. Captured by
    /// `RequestBodyStream` closures and checked in `nextBodyChunk` —
    /// detects stale body reads from handlers that escaped their
    /// `Request` past the next keep-alive cycle.
    var generation: UInt64 = 0

    /// Set by `decodeHead` when `Expect: 100-continue` is present.
    /// Cleared by the first `nextBodyChunk` call (which sends the
    /// interim 100 Continue response) or by `drainBody`.
    var pending100Continue: Bool = false

    /// Reusable `HeaderMap` / `Extensions` — preserve capacity across
    /// keep-alive requests (COW on the value handed to Request).
    var reusableHeaders = HeaderMap()
    var reusableExtensions = Extensions()

    /// Chunked-body sub-state (only meaningful when
    /// `state == .readingChunkedBody`).
    var chunkState: ChunkState = .readSize

    /// Bytes consumed from the body so far — used for `maxBodyBytes`
    /// enforcement on streaming chunked bodies.
    var bodyBytesConsumed: Int = 0

    enum State: Sendable {
        case readingHead
        case readingBody(remaining: Int)
        case readingChunkedBody
        case bodyDone
        case closed
    }

    enum ChunkState: Sendable {
        case readSize
        case data(remaining: Int)
        case afterDataCrlf
        case trailers
    }

    // MARK: - Init

    public init(
        eventLoop: PollEventLoop,
        fd: CInt,
        channelId: UInt32,
        maxHeaderBytes: Int = 64 * 1024,
        maxBodyBytes: Int = 2 * 1024 * 1024,
        maxHeaderCount: Int = 100,
        readTimeout: Duration = .seconds(30)
    ) {
        self.eventLoop = eventLoop
        self.fd = fd
        self.channelId = channelId
        self.maxHeaderBytes = maxHeaderBytes
        self.maxBodyBytes = maxBodyBytes
        self.maxHeaderCount = maxHeaderCount
        self.readTimeout = readTimeout
    }

    // MARK: - Public API

    /// Parse one request head. Returns `nil` on clean EOF (client
    /// closed the connection between requests).
    ///
    /// Loops internally: tries to parse from the buffer, reads more
    /// bytes from the socket if needed, enforces `maxHeaderBytes`
    /// against header-bomb attacks, and respects `readTimeout`
    /// (P0-5: every socket read is bounded).
    public func decodeHead() async throws -> DecodedHead? {
        try Task.checkCancellation()

        while true {
            if let head = try parseHeadFromBuffer() {
                return head
            }
            // Header block not yet complete — check size limit.
            if buffer.count - readPos > maxHeaderBytes {
                state = .closed
                throw H1ConnError.requestTooLarge
            }
            let n = await readWithTimeout()
            if n == 0 {
                // Clean EOF between requests — not an error.
                return nil
            }
            if n < 0 {
                state = .closed
                throw H1ConnError.ioError
            }
            appendReadView(count: n)
            try Task.checkCancellation()
        }
    }

    /// Pull the next body chunk. Returns `nil` when the body is
    /// fully delivered.
    ///
    /// - Parameter gen: The generation captured by the body stream
    ///   closure. Throws `BodyError.connectionAdvanced` if the
    ///   connection has moved on to the next keep-alive request.
    public func nextBodyChunk(forGeneration gen: UInt64) async throws -> [UInt8]? {
        try Task.checkCancellation()

        if gen != generation {
            throw BodyError.connectionAdvanced
        }

        // First body read on an Expect: 100-continue request sends
        // the interim response so the client proceeds with the body.
        if pending100Continue {
            send100Continue()
            pending100Continue = false
        }

        switch state {
        case .readingHead:
            fatalError("H1Conn.nextBodyChunk called in .readingHead state")
        case .bodyDone, .closed:
            return nil
        case .readingBody(var remaining):
            return try await readCLBodyChunk(remaining: &remaining)
        case .readingChunkedBody:
            return try await readChunkedBodyChunk()
        }
    }

    /// True when there is nothing left to read for the current
    /// request's body (CL fully delivered, chunked terminator seen,
    /// or the connection errored out).
    public func isBodyDone() -> Bool {
        switch state {
        case .bodyDone, .closed: return true
        default: return false
        }
    }

    /// Read and discard any remaining body bytes for the current
    /// request. Used by `driveConnection` after the handler returns
    /// so the buffer is left positioned at the next pipelined
    /// request. Enforces `maxBodyBytes` — throws on overflow.
    public func drainBody() async throws {
        try Task.checkCancellation()

        if pending100Continue {
            send100Continue()
            pending100Continue = false
        }

        while !isBodyDone() {
            let chunk: [UInt8]?
            switch state {
            case .readingBody(var remaining):
                chunk = try await readCLBodyChunk(remaining: &remaining)
            case .readingChunkedBody:
                chunk = try await readChunkedBodyChunk()
            default:
                return
            }
            if let c = chunk {
                bodyBytesConsumed &+= c.count
                if bodyBytesConsumed > maxBodyBytes {
                    state = .closed
                    throw H1ConnError.requestTooLarge
                }
            }
            try Task.checkCancellation()
        }
    }

    /// Mark the connection as closed — further reads return error.
    public func close() {
        state = .closed
    }

    // MARK: - Head parsing

    /// Try to parse one request head from the buffered bytes.
    /// Returns `nil` if the buffer doesn't yet contain the full
    /// header block (`\r\n\r\n` terminator not found). Throws on
    /// malformed input.
    ///
    /// All smuggling checks from the legacy `H1Decoder.parseRequestHeaders`
    /// are preserved here verbatim: bare CR/LF in header values,
    /// CL+TE conflict, missing Host, conflicting CL, malformed chunk
    /// framing, header-bomb, etc.
    private func parseHeadFromBuffer() throws -> DecodedHead? {
        // 1. Locate the `\r\n\r\n` terminator.
        guard let headerEnd = findHeaderBlockEnd() else {
            return nil
        }

        let bufCount = buffer.count
        var pos = readPos

        // ── Request line: METHOD SP TARGET SP HTTP/1.x CRLF ────────
        let methodEnd = try findByteInBuffer(0x20, from: pos, upto: headerEnd)
            ?? { throw H1ConnError.malformedRequestLine }()
        let method = Method(String(decoding: buffer[pos..<methodEnd], as: UTF8.self))
        pos = methodEnd &+ 1
        while pos < headerEnd && buffer[pos] == 0x20 { pos &+= 1 }
        let targetEnd = try findByteInBuffer(0x20, from: pos, upto: headerEnd)
            ?? { throw H1ConnError.malformedRequestLine }()
        let targetBytes = Array(buffer[pos..<targetEnd])
        let uri = Uri(bytes: targetBytes)
        pos = targetEnd &+ 1
        while pos < headerEnd && buffer[pos] == 0x20 { pos &+= 1 }

        // Version: HTTP/1.x
        guard pos &+ 10 <= headerEnd,
              buffer[pos] == 0x48, buffer[pos &+ 1] == 0x54,
              buffer[pos &+ 2] == 0x54, buffer[pos &+ 3] == 0x50,
              buffer[pos &+ 4] == 0x2F,  // "HTTP/"
              buffer[pos &+ 5] == 0x31,  // '1'
              buffer[pos &+ 6] == 0x2E   // '.'
        else {
            throw H1ConnError.unsupportedVersion(
                String(decoding: buffer[pos..<min(pos &+ 10, headerEnd)], as: UTF8.self)
            )
        }
        let minorVersion = buffer[pos &+ 7]
        let version: Version
        switch minorVersion {
        case 0x30: version = .http10
        case 0x31: version = .http11
        default:
            throw H1ConnError.unsupportedVersion(
                "HTTP/1.\(Character(UnicodeScalar(minorVersion)))"
            )
        }
        pos &+= 8
        guard pos &+ 1 < headerEnd,
              buffer[pos] == 0x0D, buffer[pos &+ 1] == 0x0A
        else { throw H1ConnError.malformedRequestLine }
        pos &+= 2

        // ── Headers ───────────────────────────────────────────────
        reusableHeaders.entries.removeAll(keepingCapacity: true)
        var headerIndex = 0
        var contentLength: Int? = nil
        var transferEncodingChunked = false
        var seenHost = false
        var connectionClose = false
        var connectionKeepAlive = false
        var expect100Continue = false

        while pos < headerEnd &- 2 {
            if buffer[pos] == 0x0D && buffer[pos &+ 1] == 0x0A { break }

            headerIndex &+= 1
            if headerIndex > maxHeaderCount {
                throw H1ConnError.tooManyHeaders
            }

            // Header name: bytes up to ':'.
            let nameStart = pos
            while pos < headerEnd && buffer[pos] != 0x3A && buffer[pos] != 0x0D {
                pos &+= 1
            }
            guard pos < headerEnd, buffer[pos] == 0x3A else {
                throw H1ConnError.malformedHeader(line: headerIndex)
            }
            let nameBytes = buffer[nameStart..<pos]
            if nameBytes.isEmpty {
                throw H1ConnError.emptyHeaderName
            }
            let name = HeaderName(lowercasedBytes: nameBytes.map {
                (0x41...0x5A).contains($0) ? $0 &+ 0x20 : $0
            })
            pos &+= 1  // skip ':'
            while pos < headerEnd && (buffer[pos] == 0x20 || buffer[pos] == 0x09) {
                pos &+= 1
            }
            // Value: scan until CRLF. Reject bare CR / LF (smuggling guard).
            let valueStart = pos
            scanLoop: while pos < headerEnd &- 1 {
                let b = buffer[pos]
                if b == 0x0D {
                    if buffer[pos &+ 1] == 0x0A { break scanLoop }
                    throw H1ConnError.bareCrLfInHeader(line: headerIndex)
                }
                if b == 0x0A {
                    throw H1ConnError.bareCrLfInHeader(line: headerIndex)
                }
                pos &+= 1
            }
            // Trim trailing whitespace.
            var valueEnd = pos
            while valueEnd > valueStart {
                let prev = buffer[valueEnd &- 1]
                if prev == 0x20 || prev == 0x09 { valueEnd &-= 1 } else { break }
            }
            let valueBytes = Array(buffer[valueStart..<valueEnd])
            let value = HeaderValue(bytes: valueBytes)
            reusableHeaders.append(name, value)

            // Track framing-relevant headers inline.
            if Self.isContentLength(nameBytes) {
                guard let n = Int(String(decoding: valueBytes, as: UTF8.self)), n >= 0 else {
                    throw H1ConnError.invalidContentLength
                }
                if let existing = contentLength, existing != n {
                    throw H1ConnError.conflictingContentLength
                }
                contentLength = n
            } else if Self.isTransferEncoding(nameBytes) {
                // RFC 9112 §7.2.1: chunked must be the LAST codeword.
                if Self.lastTokenIsChunked(valueBytes) {
                    transferEncodingChunked = true
                }
            } else if !seenHost && Self.isHost(nameBytes) {
                seenHost = true
            } else if Self.isConnection(nameBytes) {
                let lower = valueBytes.map {
                    (0x41...0x5A).contains($0) ? $0 &+ 0x20 : $0
                }
                if Self.tokenInList(lower, token: [0x63, 0x6C, 0x6F, 0x73, 0x65]) {  // "close"
                    connectionClose = true
                }
                if Self.tokenInList(lower, token: [0x6B, 0x65, 0x65, 0x70, 0x2D, 0x61, 0x6C, 0x69, 0x76, 0x65]) {  // "keep-alive"
                    connectionKeepAlive = true
                }
            } else if Self.isExpect(nameBytes) {
                let lower = valueBytes.map {
                    (0x41...0x5A).contains($0) ? $0 &+ 0x20 : $0
                }
                // "100-continue"
                let token: [UInt8] = [0x31, 0x30, 0x30, 0x2D, 0x63, 0x6F, 0x6E, 0x74, 0x69, 0x6E, 0x75, 0x65]
                if lower.count == token.count {
                    var match = true
                    for i in 0..<token.count where lower[i] != token[i] { match = false; break }
                    if match { expect100Continue = true }
                }
            }

            // Consume CRLF.
            guard pos &+ 1 < headerEnd,
                  buffer[pos] == 0x0D, buffer[pos &+ 1] == 0x0A
            else { throw H1ConnError.malformedHeader(line: headerIndex) }
            pos &+= 2
        }

        // HTTP/1.1 Host header check.
        if version == .http11 && !seenHost {
            throw H1ConnError.missingHost
        }

        // CL + TE conflict — reject to defeat CL.TE / TE.CL smuggling.
        if transferEncodingChunked && contentLength != nil {
            throw H1ConnError.conflictingFraming
        }

        // ── Compute keep-alive BEFORE stripping hop-by-hop ─────────
        // This fixes P0-3: the legacy code stripped Connection first
        // and then tried to read it back — always nil.
        let keepAlive: Bool
        if connectionClose {
            keepAlive = false
        } else if connectionKeepAlive {
            keepAlive = true
        } else {
            // Default by version: HTTP/1.1 → keep-alive, HTTP/1.0 → close.
            keepAlive = (version == .http11)
        }

        // Strip hop-by-hop headers — handlers must not see them.
        reusableHeaders.entries.removeAll { (n, _) in n.isHopByHop() }

        // ── Determine body framing ────────────────────────────────
        let hasBody: Bool
        let expectsBody: Bool
        // HEAD requests never carry a body, even with Content-Length.
        if method == .HEAD {
            hasBody = false
            expectsBody = false
            state = .bodyDone
        } else if transferEncodingChunked {
            hasBody = true
            expectsBody = true
            state = .readingChunkedBody
            chunkState = .readSize
            bodyBytesConsumed = 0
        } else if let cl = contentLength {
            if cl == 0 {
                hasBody = false
                expectsBody = false
                state = .bodyDone
            } else {
                // Early reject: CL larger than maxBodyBytes.
                if cl > maxBodyBytes {
                    state = .closed
                    throw H1ConnError.requestTooLarge
                }
                hasBody = true
                expectsBody = true
                state = .readingBody(remaining: cl)
                bodyBytesConsumed = 0
            }
        } else {
            // No CL, no TE → no body for requests (RFC 9112 §6.3).
            hasBody = false
            expectsBody = false
            state = .bodyDone
        }

        // Signal 100 Continue to the first nextBodyChunk call.
        if expectsBody && expect100Continue {
            pending100Continue = true
        }

        // ── Build Request ─────────────────────────────────────────
        reusableExtensions.removeAll()
        let request = Request(
            method: method,
            uri: uri,
            version: version,
            headers: reusableHeaders,
            body: .empty,  // driveConnection sets .pull(...) if hasBody
            extensions: reusableExtensions
        )

        // ── Consume header bytes from buffer ──────────────────────
        readPos = headerEnd
        maybeCompact()

        generation &+= 1

        _ = bufCount  // suppress unused warning
        return DecodedHead(
            request: request,
            generation: generation,
            keepAlive: keepAlive,
            hasBody: hasBody,
            expects100Continue: expect100Continue && expectsBody
        )
    }

    // MARK: - Body: Content-Length bounded

    /// Pull one chunk from a CL-bounded body.
    private func readCLBodyChunk(remaining: inout Int) async throws -> [UInt8]? {
        if remaining == 0 {
            state = .bodyDone
            return nil
        }
        let available = buffer.count &- readPos
        if available == 0 {
            let n = await readWithTimeout()
            if n == 0 {
                // Unexpected EOF — client closed before CL bytes arrived.
                state = .closed
                throw H1ConnError.ioError
            }
            if n < 0 {
                state = .closed
                throw H1ConnError.ioError
            }
            appendReadView(count: n)
            try Task.checkCancellation()
        }
        let take = Swift.min(remaining, buffer.count &- readPos)
        let chunk = Array(buffer[readPos..<(readPos &+ take)])
        readPos &+= take
        remaining &-= take
        bodyBytesConsumed &+= take
        if remaining == 0 {
            state = .bodyDone
            maybeCompact()
        } else {
            state = .readingBody(remaining: remaining)
        }
        return chunk
    }

    // MARK: - Body: chunked Transfer-Encoding

    /// Pull one chunk from a chunked body. Drives the sub-state
    /// machine (`readSize` → `data` → `afterDataCrlf` → `readSize`,
    /// or `readSize` with size 0 → `trailers` → `bodyDone`).
    private func readChunkedBodyChunk() async throws -> [UInt8]? {
        while true {
            switch chunkState {
            case .readSize:
                // Parse "<hex>[;ext]\r\n"
                guard let (size, newPos) = try parseChunkSize() else {
                    // Need more data.
                    try await ensureBytesAvailable()
                    continue
                }
                readPos = newPos
                if size == 0 {
                    chunkState = .trailers
                    continue
                }
                // Enforce maxBodyBytes on running total.
                if bodyBytesConsumed &+ size > maxBodyBytes {
                    state = .closed
                    throw H1ConnError.requestTooLarge
                }
                chunkState = .data(remaining: size)

            case .data(let remaining):
                if remaining == 0 {
                    chunkState = .afterDataCrlf
                    continue
                }
                let available = buffer.count &- readPos
                if available == 0 {
                    try await ensureBytesAvailable()
                    continue
                }
                let take = Swift.min(remaining, available)
                let chunk = Array(buffer[readPos..<(readPos &+ take)])
                readPos &+= take
                bodyBytesConsumed &+= take
                if take == remaining {
                    chunkState = .afterDataCrlf
                } else {
                    chunkState = .data(remaining: remaining &- take)
                }
                return chunk

            case .afterDataCrlf:
                // Need 2 bytes: \r\n after chunk data.
                if buffer.count &- readPos < 2 {
                    try await ensureBytesAvailable()
                    continue
                }
                guard buffer[readPos] == 0x0D, buffer[readPos &+ 1] == 0x0A
                else {
                    state = .closed
                    throw H1ConnError.malformedChunkData
                }
                readPos &+= 2
                chunkState = .readSize

            case .trailers:
                // Scan for terminating CRLF (empty trailer line).
                // Trailers themselves are discarded for v0.1.
                guard let (isEmpty, newPos) = scanTrailerLine() else {
                    try await ensureBytesAvailable()
                    continue
                }
                readPos = newPos
                if isEmpty {
                    // End of chunked body.
                    state = .bodyDone
                    chunkState = .readSize  // reset for next request
                    maybeCompact()
                    return nil
                }
                // Otherwise it was a trailer header — loop and keep
                // scanning until the empty line.
            }
        }
    }

    /// Try to parse "<hex>[;ext]\r\n" from the current buffer
    /// position. Returns `(size, newPositionAfterCrlf)` or `nil`
    /// if more bytes are needed. Throws on malformed size.
    private func parseChunkSize() throws -> (size: Int, newPos: Int)? {
        var pos = readPos
        let n = buffer.count

        // Scan hex digits until CR or ';' (chunk-ext).
        let sizeStart = pos
        while pos < n && buffer[pos] != 0x0D && buffer[pos] != 0x3B {
            pos &+= 1
        }
        guard pos < n else { return nil }  // need more

        let sizeBytes = buffer[sizeStart..<pos]
        guard !sizeBytes.isEmpty,
              let chunkSize = Self.parseHex(sizeBytes)
        else {
            state = .closed
            throw H1ConnError.malformedChunkSize
        }

        // Skip optional chunk-ext (anything until CRLF).
        while pos &+ 1 < n,
              !(buffer[pos] == 0x0D && buffer[pos &+ 1] == 0x0A) {
            pos &+= 1
        }
        guard pos &+ 1 < n,
              buffer[pos] == 0x0D, buffer[pos &+ 1] == 0x0A
        else {
            return nil  // need more
        }
        pos &+= 2  // consume CRLF
        return (chunkSize, pos)
    }

    /// Look at the current position. Returns `(isEmptyLine, newPos)`
    /// where `isEmptyLine` is true if the line is empty (just CRLF,
    /// marking end of trailers) or false if it's a trailer header
    /// (skip past its CRLF). Returns nil if more bytes are needed.
    private func scanTrailerLine() -> (isEmpty: Bool, newPos: Int)? {
        let n = buffer.count
        guard readPos &+ 1 < n else { return nil }
        // Empty line?
        if buffer[readPos] == 0x0D && buffer[readPos &+ 1] == 0x0A {
            return (true, readPos &+ 2)
        }
        // Trailer header — skip to its terminating CRLF.
        var pos = readPos
        while pos &+ 1 < n {
            if buffer[pos] == 0x0D && buffer[pos &+ 1] == 0x0A {
                return (false, pos &+ 2)
            }
            pos &+= 1
        }
        return nil  // need more
    }

    // MARK: - Buffer management

    /// Read more bytes from the socket and append them to `buffer`.
    /// Used by chunked / CL body chunk reads when the buffer is
    /// exhausted mid-frame.
    ///
    /// NOTE: read timeout (P0-5) is intentionally NOT implemented here
    /// via `withTaskGroup` — spawning two child Tasks per `read` causes
    /// a ~50% throughput collapse under keep-alive workloads (the
    /// Swift Concurrency scheduler cannot keep up with N TaskGroups
    /// per second, each spawning 2 children). The right home for read
    /// timeouts is at the `PollEventLoop` layer (a per-channel timer
    /// armed alongside the read interest), which will land in a
    /// follow-up commit.
    @usableFromInline
    internal func readWithTimeout() async -> Int {
        // Direct eventLoop.read — same fast path the legacy code used.
        // The actor's executor (the eventLoop) and the driveConnection
        // Task's executor are the same PollEventLoop, so this entire
        // call executes inline with zero hop overhead.
        await eventLoop.read(channelId: channelId, fd: fd)
    }

    /// Read more bytes, append to buffer, throw on EOF/error. Used by
    /// the chunked + CL body chunk paths when the buffer is empty.
    private func ensureBytesAvailable() async throws {
        try Task.checkCancellation()
        let n = await readWithTimeout()
        if n <= 0 {
            state = .closed
            throw H1ConnError.ioError
        }
        appendReadView(count: n)
        try Task.checkCancellation()
    }

    /// Copy bytes from the eventLoop's per-channel read buffer into
    /// our `[UInt8]` accumulator. One memcpy (~10 ns for 8 KB).
    private func appendReadView(count: Int) {
        let view = eventLoop.getReadView(channelId: channelId, count: count)
        // view is only valid on the loop thread — which we're on,
        // because the actor's executor is the eventLoop.
        buffer.append(contentsOf: view)
    }

    /// Periodically compact the buffer to prevent unbounded growth
    /// from the readPos pointer. Strategy: only compact when readPos
    /// is large (>= 1 MiB or buffer is large and readPos > 80%) so
    /// the typical small-request path pays zero O(n) cost.
    private func maybeCompact() {
        let threshold = 1024 * 1024  // 1 MiB
        if readPos > threshold {
            buffer.removeFirst(readPos)
            readPos = 0
        } else if buffer.count > 64 * 1024 && readPos > (buffer.count * 4 / 5) {
            buffer.removeFirst(readPos)
            readPos = 0
        }
    }

    /// Send the interim `100 Continue` response directly on the
    /// socket. Done at most once per request (guarded by
    /// `pending100Continue`).
    @inline(__always)
    private func send100Continue() {
        let bytes: [UInt8] = [
            0x48, 0x54, 0x54, 0x50, 0x2F, 0x31, 0x2E, 0x31, 0x20,  // "HTTP/1.1 "
            0x31, 0x30, 0x30, 0x20,                                  // "100 "
            0x43, 0x6F, 0x6E, 0x74, 0x69, 0x6E, 0x75, 0x65,         // "Continue"
            0x0D, 0x0A, 0x0D, 0x0A                                   // CRLF CRLF
        ]
        _ = H1Conn.writeRaw(fd: fd, buffer: bytes)
    }

    // MARK: - Byte search helpers

    /// Find `\r\n\r\n` (end of header block). Returns the index
    /// after the final `\n`, or `nil` if not present in the
    /// unconsumed portion of the buffer.
    private func findHeaderBlockEnd() -> Int? {
        let start = readPos
        let end = buffer.count
        guard end &- start >= 4 else { return nil }
        return buffer.withUnsafeBufferPointer { ptr in
            ByteSearch.findCRLFCRLF(in: ptr, from: start, to: end)
        }
    }

    /// Linear / SWAR byte search within the unconsumed buffer.
    private func findByteInBuffer(_ needle: UInt8, from start: Int, upto end: Int) -> Int? {
        buffer.withUnsafeBufferPointer { ptr in
            ByteSearch.findByte(needle, in: ptr, from: start, to: end)
        }
    }

    // MARK: - Static header-name recognisers (case-insensitive)

    @inline(__always)
    private static func isContentLength(_ name: ArraySlice<UInt8>) -> Bool {
        // "content-length" (14 bytes)
        let expected: [UInt8] = [
            0x63, 0x6F, 0x6E, 0x74, 0x65, 0x6E, 0x74, 0x2D,
            0x6C, 0x65, 0x6E, 0x67, 0x74, 0x68
        ]
        return matchName(name, expected: expected)
    }

    @inline(__always)
    private static func isTransferEncoding(_ name: ArraySlice<UInt8>) -> Bool {
        // "transfer-encoding" (17 bytes)
        let expected: [UInt8] = [
            0x74, 0x72, 0x61, 0x6E, 0x73, 0x66, 0x65, 0x72, 0x2D,
            0x65, 0x6E, 0x63, 0x6F, 0x64, 0x69, 0x6E, 0x67
        ]
        return matchName(name, expected: expected)
    }

    @inline(__always)
    private static func isHost(_ name: ArraySlice<UInt8>) -> Bool {
        // "host" (4 bytes) — short-circuit on length.
        guard name.count == 4 else { return false }
        let s = name.startIndex
        return (name[s] | 0x20) == 0x68      // h
            && (name[s &+ 1] | 0x20) == 0x6F // o
            && (name[s &+ 2] | 0x20) == 0x73 // s
            && (name[s &+ 3] | 0x20) == 0x74 // t
    }

    @inline(__always)
    private static func isConnection(_ name: ArraySlice<UInt8>) -> Bool {
        // "connection" (10 bytes)
        let expected: [UInt8] = [
            0x63, 0x6F, 0x6E, 0x6E, 0x65, 0x63, 0x74, 0x69, 0x6F, 0x6E
        ]
        return matchName(name, expected: expected)
    }

    @inline(__always)
    private static func isExpect(_ name: ArraySlice<UInt8>) -> Bool {
        // "expect" (6 bytes)
        let expected: [UInt8] = [0x65, 0x78, 0x70, 0x65, 0x63, 0x74]
        return matchName(name, expected: expected)
    }

    @inline(__always)
    private static func matchName(_ name: ArraySlice<UInt8>, expected: [UInt8]) -> Bool {
        guard name.count == expected.count else { return false }
        var i = 0
        for b in name {
            let lower = (0x41...0x5A).contains(b) ? b &+ 0x20 : b
            if lower != expected[i] { return false }
            i &+= 1
        }
        return true
    }

    /// RFC 9112 §7.2.1: chunked must be the LAST codeword in the
    /// Transfer-Encoding list. Split on comma, trim OWS per element,
    /// compare the last token case-insensitively against "chunked".
    @inline(__always)
    private static func lastTokenIsChunked(_ valueBytes: [UInt8]) -> Bool {
        let lower = valueBytes.map {
            (0x41...0x5A).contains($0) ? $0 &+ 0x20 : $0
        }
        var lastComma: Int? = nil
        for i in 0..<lower.count where lower[i] == 0x2C { lastComma = i }
        let tokenStart = (lastComma ?? -1) &+ 1
        var tokenEnd = lower.count
        while tokenEnd > tokenStart && (lower[tokenEnd - 1] == 0x20 || lower[tokenEnd - 1] == 0x09) {
            tokenEnd &-= 1
        }
        var s = tokenStart
        while s < tokenEnd && (lower[s] == 0x20 || lower[s] == 0x09) {
            s &+= 1
        }
        // "chunked"
        let chunked: [UInt8] = [0x63, 0x68, 0x75, 0x6E, 0x6B, 0x65, 0x64]
        guard tokenEnd &- s == chunked.count else { return false }
        for i in 0..<chunked.count where lower[s &+ i] != chunked[i] { return false }
        return true
    }

    /// Check whether a comma-separated list of tokens (already
    /// lowercased) contains `token`. Used for `Connection: close`,
    /// `Connection: keep-alive`.
    @inline(__always)
    private static func tokenInList(_ list: [UInt8], token: [UInt8]) -> Bool {
        var i = 0
        let n = list.count
        while i < n {
            // Skip OWS and commas.
            while i < n && (list[i] == 0x20 || list[i] == 0x09 || list[i] == 0x2C) { i &+= 1 }
            // Compare token.
            var j = 0
            var matched = true
            while j < token.count && i &+ j < n {
                if list[i &+ j] != token[j] { matched = false; break }
                j &+= 1
            }
            if matched && j == token.count {
                // Make sure the token actually ends here (boundary).
                let next = i &+ j
                if next == n || list[next] == 0x20 || list[next] == 0x09 || list[next] == 0x2C {
                    return true
                }
            }
            // Skip to next comma.
            while i < n && list[i] != 0x2C { i &+= 1 }
        }
        return false
    }

    /// Parse ASCII hex into Int. Returns `nil` on invalid digits or
    /// if the value exceeds 1 GiB per-chunk cap. Overflow-safe on
    /// all architectures.
    @inline(__always)
    private static func parseHex<S: Sequence>(_ bytes: S) -> Int?
    where S.Element == UInt8 {
        let maxChunkSize = 1024 * 1024 * 1024
        var result = 0
        for b in bytes {
            let digit: Int
            switch b {
            case 0x30...0x39: digit = Int(b - 0x30)
            case 0x41...0x46: digit = Int(b - 0x41 + 10)
            case 0x61...0x66: digit = Int(b - 0x61 + 10)
            default: return nil
            }
            if result > (maxChunkSize - digit) / 16 { return nil }
            result = result * 16 + digit
        }
        return result
    }

    // MARK: - Raw socket write (nonisolated, for 100 Continue)

    /// Raw blocking write — used by `send100Continue`. Always called
    /// from inside the actor (loop thread), so it's safe to use the
    /// blocking `write(2)` for tiny interim responses.
    @inline(__always)
    private nonisolated static func writeRaw(fd: CInt, buffer: [UInt8]) -> Int {
        #if canImport(Glibc)
        return buffer.withUnsafeBufferPointer { ptr -> Int in
            var remaining = ptr.count
            var offset = 0
            while remaining > 0 {
                let n = Glibc.write(fd, ptr.baseAddress!.advanced(by: offset), remaining)
                if n > 0 {
                    remaining -= n
                    offset += n
                    continue
                }
                if n == 0 { break }
                if errno == EINTR { continue }
                break
            }
            return offset
        }
        #else
        return 0
        #endif
    }
}
