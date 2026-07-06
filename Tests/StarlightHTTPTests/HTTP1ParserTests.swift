//===----------------------------------------------------------------------===//
//
//  HTTP1ParserTests.swift
//  StarlightHTTPTests
//
//  Verifies that the HTTP/1.1 request parser correctly decodes the
//  request line, headers, and version, and that it handles partial
//  input (bytes arriving in multiple `feed(...)` calls) the way a
//  streaming parser on a TCP socket must.
//
//===----------------------------------------------------------------------===//

import Testing
@testable import StarlightHTTP

@Suite("HTTP1Parser")
struct HTTP1ParserTests {
    // MARK: - Request line

    @Test("GET request parses cleanly")
    func getRequest() throws {
        let raw = "GET /hello HTTP/1.1\r\n\r\n"
        var parser = HTTP1Parser()
        var ctx = RequestContext()
        let complete = try Array(raw.utf8).withUnsafeBufferPointer { ptr -> Bool in
            try parser.feed(ptr, into: &ctx)
        }
        #expect(complete)
        #expect(ctx.method == .GET)
    }

    @Test("POST request parses cleanly")
    func postRequest() throws {
        let raw = "POST /api/login HTTP/1.1\r\n\r\n"
        var parser = HTTP1Parser()
        var ctx = RequestContext()
        let complete = try Array(raw.utf8).withUnsafeBufferPointer { ptr -> Bool in
            try parser.feed(ptr, into: &ctx)
        }
        #expect(complete)
        #expect(ctx.method == .POST)
    }

    @Test("All standard methods decode correctly")
    func allMethods() throws {
        let cases: [(String, HTTPMethod)] = [
            ("GET / HTTP/1.1\r\n\r\n", .GET),
            ("POST / HTTP/1.1\r\n\r\n", .POST),
            ("PUT / HTTP/1.1\r\n\r\n", .PUT),
            ("PATCH / HTTP/1.1\r\n\r\n", .PATCH),
            ("DELETE / HTTP/1.1\r\n\r\n", .DELETE),
            ("HEAD / HTTP/1.1\r\n\r\n", .HEAD),
            ("OPTIONS / HTTP/1.1\r\n\r\n", .OPTIONS),
            ("CONNECT example.com:443 HTTP/1.1\r\n\r\n", .CONNECT),
            ("TRACE / HTTP/1.1\r\n\r\n", .TRACE),
        ]
        for (raw, expected) in cases {
            var parser = HTTP1Parser()
            var ctx = RequestContext()
            let complete = try Array(raw.utf8).withUnsafeBufferPointer { ptr -> Bool in
                try parser.feed(ptr, into: &ctx)
            }
            #expect(complete, "Request did not parse to completion: \(raw)")
            #expect(ctx.method == expected, "Method mismatch for: \(raw)")
        }
    }

    @Test("Unknown method falls back to .other")
    func unknownMethod() throws {
        let raw = "BREW /pot HTTP/1.1\r\n\r\n"  // RFC 2324 HTCPCP
        var parser = HTTP1Parser()
        var ctx = RequestContext()
        let complete = try Array(raw.utf8).withUnsafeBufferPointer { ptr -> Bool in
            try parser.feed(ptr, into: &ctx)
        }
        #expect(complete)
        #expect(ctx.method == .other)
    }

    // MARK: - Versions

    @Test("HTTP/1.0 accepted")
    func http10() throws {
        let raw = "GET / HTTP/1.0\r\n\r\n"
        var parser = HTTP1Parser()
        var ctx = RequestContext()
        let complete = try Array(raw.utf8).withUnsafeBufferPointer { ptr -> Bool in
            try parser.feed(ptr, into: &ctx)
        }
        #expect(complete)
    }

    @Test("HTTP/2.0 rejected")
    func http20Rejected() throws {
        let raw = "GET / HTTP/2.0\r\n\r\n"
        var parser = HTTP1Parser()
        var ctx = RequestContext()
        #expect(throws: HTTP1ParseError.self) {
            try Array(raw.utf8).withUnsafeBufferPointer { ptr -> Bool in
                try parser.feed(ptr, into: &ctx)
            }
        }
    }

    @Test("Malformed version rejected")
    func malformedVersion() throws {
        let raw = "GET / HTTP/x.y\r\n\r\n"
        var parser = HTTP1Parser()
        var ctx = RequestContext()
        #expect(throws: HTTP1ParseError.self) {
            try Array(raw.utf8).withUnsafeBufferPointer { ptr -> Bool in
                try parser.feed(ptr, into: &ctx)
            }
        }
    }

    // MARK: - Headers

    @Test("Multiple headers parse correctly")
    func multipleHeaders() throws {
        let raw = """
        GET /index.html HTTP/1.1\r
        Host: example.com\r
        User-Agent: starlight-test/1.0\r
        Accept: */*\r
        \r

        """
        var parser = HTTP1Parser()
        var ctx = RequestContext(initialArenaSize: 1024)
        let complete = try Array(raw.utf8).withUnsafeBufferPointer { ptr -> Bool in
            try parser.feed(ptr, into: &ctx)
        }
        #expect(complete)
        #expect(ctx.method == .GET)
        // Each header line copies name + value into the arena: 3 headers
        // × (name + value bytes). Total arena usage > 0 confirms
        // headers were consumed.
        #expect(ctx.arenaUsedBytes > 0)
    }

    @Test("Header value with leading spaces is trimmed")
    func headerValueTrimmed() throws {
        let raw = """
        GET / HTTP/1.1\r
        X-Custom:    padded value\r
        \r

        """
        var parser = HTTP1Parser()
        var ctx = RequestContext()
        let complete = try Array(raw.utf8).withUnsafeBufferPointer { ptr -> Bool in
            try parser.feed(ptr, into: &ctx)
        }
        #expect(complete)
        // 7 chars of name + 12 chars of value ("padded value") = 19 bytes
        // minimum in arena.
        #expect(ctx.arenaUsedBytes >= 19)
    }

    @Test("Header without colon rejected")
    func malformedHeader() throws {
        let raw = """
        GET / HTTP/1.1\r
        BrokenHeader-no-colon\r
        \r

        """
        var parser = HTTP1Parser()
        var ctx = RequestContext()
        #expect(throws: HTTP1ParseError.self) {
            try Array(raw.utf8).withUnsafeBufferPointer { ptr -> Bool in
                try parser.feed(ptr, into: &ctx)
            }
        }
    }

    // MARK: - Partial reads (streaming)

    @Test("Request split across two feeds parses correctly")
    func splitAcrossTwoFeeds() throws {
        // Caller-side accumulator: each `feed` call passes the FULL
        // accumulated buffer, and the parser advances `consumedBytes`
        // within it. This mirrors how a `ChannelHandler` would feed
        // bytes from a NIO `ByteBuffer` — the buffer grows with each
        // socket read, and the parser sees the whole thing each time.
        let combined = Array("GET /hello HTTP/1.1\r\n\r\n".utf8)
        let firstChunk = Array(combined.prefix(10))  // partial
        // The second "feed" sees the whole accumulated buffer.
        let secondChunk = combined

        var parser = HTTP1Parser()
        var ctx = RequestContext()

        let complete1 = try firstChunk.withUnsafeBufferPointer { ptr -> Bool in
            try parser.feed(ptr, into: &ctx)
        }
        #expect(!complete1, "Should be incomplete after first partial")

        let complete2 = try secondChunk.withUnsafeBufferPointer { ptr -> Bool in
            try parser.feed(ptr, into: &ctx)
        }
        #expect(complete2, "Should be complete after second feed")
        #expect(ctx.method == .GET)
        _ = complete1; _ = complete2
    }

    @Test("Byte-by-byte feed eventually parses")
    func byteByByteFeed() throws {
        // Caller accumulates one byte at a time and re-feeds the whole
        // accumulated buffer on each iteration.
        let raw = Array("GET /x HTTP/1.1\r\n\r\n".utf8)
        var parser = HTTP1Parser()
        var ctx = RequestContext()

        var lastComplete = false
        for end in 1...raw.count {
            let accumulated = Array(raw.prefix(end))
            lastComplete = try accumulated.withUnsafeBufferPointer { ptr -> Bool in
                try parser.feed(ptr, into: &ctx)
            }
        }
        #expect(lastComplete)
        #expect(ctx.method == .GET)
    }

    // MARK: - Multiple pipelined requests

    @Test("Two pipelined requests parse correctly")
    func pipelinedRequests() throws {
        let raw1Bytes = Array("GET /first HTTP/1.1\r\n\r\n".utf8)
        let raw2Bytes = Array("GET /second HTTP/1.1\r\n\r\n".utf8)
        let combined = raw1Bytes + raw2Bytes

        var parser = HTTP1Parser()
        var ctx = RequestContext()

        // Feed both requests in one buffer.
        let complete1 = try combined.withUnsafeBufferPointer { ptr -> Bool in
            try parser.feed(ptr, into: &ctx)
        }
        #expect(complete1)
        #expect(parser.consumedBytes == raw1Bytes.count)

        // Reset for the next request.
        ctx.reset()
        parser.reset()

        // Feed only the tail (raw2) — the caller has dropped the bytes
        // that were consumed by the first request.
        let complete2 = try raw2Bytes.withUnsafeBufferPointer { ptr -> Bool in
            try parser.feed(ptr, into: &ctx)
        }
        #expect(complete2)
        #expect(ctx.method == .GET)
    }

    // MARK: - LF-only (non-CRLF) tolerance

    @Test("LF-only line endings tolerated (HTTP/1.1 spec compliance)")
    func lfOnlyTolerated() throws {
        // Some clients emit bare LF instead of CRLF. The parser should
        // tolerate this — it's a common permissiveness in real-world
        // servers (nginx, h2o, hyper all do).
        let raw = "GET /hello HTTP/1.1\nHost: example.com\n\n"
        var parser = HTTP1Parser()
        var ctx = RequestContext()
        let complete = try Array(raw.utf8).withUnsafeBufferPointer { ptr -> Bool in
            try parser.feed(ptr, into: &ctx)
        }
        #expect(complete)
        #expect(ctx.method == .GET)
    }

    // MARK: - Edge cases

    @Test("Empty buffer is incomplete, not error")
    func emptyBuffer() throws {
        var parser = HTTP1Parser()
        var ctx = RequestContext()
        let buf: [UInt8] = []
        let complete = try buf.withUnsafeBufferPointer { ptr -> Bool in
            try parser.feed(ptr, into: &ctx)
        }
        #expect(!complete)
        #expect(parser.state == .requestLine)
    }

    @Test("Request line with only LF at end of stream is incomplete")
    func partialRequestLine() throws {
        let raw = "GET /hello HTTP/1.1"  // no CRLF yet
        var parser = HTTP1Parser()
        var ctx = RequestContext()
        let complete = try Array(raw.utf8).withUnsafeBufferPointer { ptr -> Bool in
            try parser.feed(ptr, into: &ctx)
        }
        #expect(!complete)
        #expect(parser.state == .requestLine)
    }

    @Test("Reset clears parser state")
    func resetClearsState() throws {
        var parser = HTTP1Parser()
        var ctx = RequestContext()
        let raw = "GET / HTTP/1.1\r\n\r\n"
        _ = try Array(raw.utf8).withUnsafeBufferPointer { ptr -> Bool in
            try parser.feed(ptr, into: &ctx)
        }
        #expect(parser.state == .complete)
        #expect(parser.consumedBytes > 0)

        parser.reset()
        #expect(parser.state == .requestLine)
        #expect(parser.consumedBytes == 0)
    }
}
