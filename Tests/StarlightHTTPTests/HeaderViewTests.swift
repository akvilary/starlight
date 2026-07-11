//===----------------------------------------------------------------------===//
//
//  HeaderViewTests.swift
//  StarlightHTTPTests
//
//  Verifies that the lazy HeaderView correctly exposes the headers
//  captured by the HTTP/1 parser. The parser copies the entire header
//  block into a reusable ByteBuffer; HeaderView walks that block on
//  demand when subscript is called.
//
//===----------------------------------------------------------------------===//

import Testing
@testable import StarlightHTTP

@Suite("HeaderView")
struct HeaderViewTests {
    /// Parse a full request and exercise the resulting HeaderView.
    private func parseRequest(_ raw: String) throws -> RequestContext {
        var parser = HTTP1Parser()
        var ctx = RequestContext()
        let bytes = Array(raw.utf8)
        let complete = try bytes.withUnsafeBufferPointer { ptr -> Bool in
            try parser.feed(ptr, into: &ctx)
        }
        #expect(complete, "Request did not parse to completion")
        return ctx
    }

    @Test("Single header is readable")
    func singleHeader() throws {
        let ctx = try parseRequest("""
        GET / HTTP/1.1\r
        Host: example.com\r
        \r

        """)
        #expect(ctx.headers["Host"] == "example.com")
        #expect(ctx.headers["HOST"] == "example.com")  // case-insensitive
        #expect(ctx.headers["host"] == "example.com")
    }

    @Test("Multiple headers all readable")
    func multipleHeaders() throws {
        let ctx = try parseRequest("""
        GET / HTTP/1.1\r
        Host: example.com\r
        User-Agent: starlight-test/1.0\r
        Accept: */*\r
        Accept-Language: en-US\r
        X-Custom: 42\r
        \r

        """)
        #expect(ctx.headers["Host"] == "example.com")
        #expect(ctx.headers["User-Agent"] == "starlight-test/1.0")
        #expect(ctx.headers["Accept"] == "*/*")
        #expect(ctx.headers["Accept-Language"] == "en-US")
        #expect(ctx.headers["X-Custom"] == "42")
    }

    @Test("Missing header returns nil")
    func missingHeader() throws {
        let ctx = try parseRequest("""
        GET / HTTP/1.1\r
        Host: example.com\r
        \r

        """)
        #expect(ctx.headers["Authorization"] == nil)
        #expect(ctx.headers[""] == nil)
    }

    @Test("Header value leading whitespace is trimmed")
    func leadingWhitespaceTrimmed() throws {
        // RFC 7230 §3.2.4 — optional leading whitespace in field-value
        // is treated as part of the value *only* if the recipient
        // chooses to preserve it; common practice (and what most
        // servers do) is to strip a single leading space after the
        // colon. Our parser strips all leading SP/HTAB.
        let ctx = try parseRequest("""
        GET / HTTP/1.1\r
        X-Padded:    value-with-spaces\r
        \r

        """)
        #expect(ctx.headers["X-Padded"] == "value-with-spaces")
    }

    @Test("Header value can contain colons")
    func valueWithColons() throws {
        // Common case: time values, URLs, base64 with padding.
        let ctx = try parseRequest("""
        GET / HTTP/1.1\r
        If-Modified-Since: Wed, 21 Oct 2015 07:28:00 GMT\r
        X-URL: http://example.com/path?query=value\r
        \r

        """)
        #expect(ctx.headers["If-Modified-Since"] == "Wed, 21 Oct 2015 07:28:00 GMT")
        #expect(ctx.headers["X-URL"] == "http://example.com/path?query=value")
    }

    @Test("Empty header section exposes no headers but is not an error")
    func emptyHeaderSection() throws {
        let ctx = try parseRequest("""
        GET / HTTP/1.1\r
        \r

        """)
        #expect(ctx.headers["Host"] == nil)
        #expect(ctx.headers.isEmpty)
    }

    @Test("Multi-valued header: values(for:) returns all in order")
    func multiValuedHeader() throws {
        let ctx = try parseRequest("""
        GET / HTTP/1.1\r
        X-Multi: one\r
        X-Multi: two\r
        X-Multi: three\r
        \r

        """)
        let values = ctx.headers.values(for: "X-Multi")
        #expect(values == ["one", "two", "three"])
        // Subscript returns the first.
        #expect(ctx.headers["X-Multi"] == "one")
    }

    @Test("count reports the captured header count")
    func count() throws {
        let ctx = try parseRequest("""
        GET / HTTP/1.1\r
        Host: example.com\r
        Accept: */*\r
        X-Custom: 42\r
        \r

        """)
        #expect(ctx.headers.count == 3)
    }

    @Test("LF-only line endings tolerated (not just CRLF)")
    func lfOnlyTolerated() throws {
        let ctx = try parseRequest("GET / HTTP/1.1\nHost: example.com\n\n")
        #expect(ctx.headers["Host"] == "example.com")
    }

    @Test("Large header value (>15 bytes — non-small-string) is read correctly")
    func largeHeaderValue() throws {
        let longValue = String(repeating: "a", count: 200)
        let ctx = try parseRequest("""
        GET / HTTP/1.1\r
        X-Long: \(longValue)\r
        \r

        """)
        #expect(ctx.headers["X-Long"] == longValue)
    }

    @Test("Reset between requests clears the header view")
    func resetClearsHeaders() throws {
        let ctx = try parseRequest("""
        GET / HTTP/1.1\r
        Host: example.com\r
        \r

        """)
        #expect(ctx.headers["Host"] == "example.com")
        var mutableCtx = ctx
        mutableCtx.reset()
        #expect(mutableCtx.headers["Host"] == nil)
        #expect(mutableCtx.headers.isEmpty)
    }
}
