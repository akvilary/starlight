//===----------------------------------------------------------------------===//
//
//  QueryViewTests.swift
//  StarlightHTTPTests
//
//  Verifies that the lazy QueryView correctly exposes the query string
//  captured by the HTTP/1 parser. The parser copies the query bytes
//  into a reusable ByteBuffer; QueryView walks that block on demand
//  when subscript is called and URL-decodes the matched value.
//
//===----------------------------------------------------------------------===//

import Testing
@testable import StarlightHTTP

@Suite("QueryView")
struct QueryViewTests {

    /// Parse a full request line and exercise the resulting QueryView.
    /// The query string is captured by the parser during request-line
    /// parsing (no headers/body needed for these tests).
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

    // MARK: - Absence / empty

    @Test("No query string → ctx.query is empty")
    func noQuery() throws {
        let ctx = try parseRequest("GET /users/42 HTTP/1.1\r\n\r\n")
        #expect(ctx.query.isEmpty)
        #expect(ctx.query["foo"] == nil)
        #expect(ctx.query.count == 0)
    }

    @Test("Question mark with empty query → empty QueryView")
    func trailingQuestionMark() throws {
        let ctx = try parseRequest("GET /search? HTTP/1.1\r\n\r\n")
        #expect(ctx.query.isEmpty)  // zero-length query → empty block
        #expect(ctx.query["foo"] == nil)
    }

    // MARK: - Basic single-value cases

    @Test("Single key=value pair")
    func singlePair() throws {
        let ctx = try parseRequest("GET /search?q=hello HTTP/1.1\r\n\r\n")
        #expect(ctx.query["q"] == "hello")
        #expect(ctx.query["missing"] == nil)
        #expect(ctx.query.count == 1)
        #expect(!ctx.query.isEmpty)
    }

    @Test("Multiple key=value pairs")
    func multiplePairs() throws {
        let ctx = try parseRequest(
            "GET /search?q=hello&page=3&lang=en HTTP/1.1\r\n\r\n"
        )
        #expect(ctx.query["q"] == "hello")
        #expect(ctx.query["page"] == "3")
        #expect(ctx.query["lang"] == "en")
        #expect(ctx.query.count == 3)
    }

    // MARK: - Edge cases

    @Test("Key without `=` → empty value")
    func keyWithoutEquals() throws {
        let ctx = try parseRequest("GET /?flag HTTP/1.1\r\n\r\n")
        #expect(ctx.query["flag"] == "")
        #expect(ctx.query.count == 1)
    }

    @Test("Key with empty value (`?key=`)")
    func emptyValue() throws {
        let ctx = try parseRequest("GET /?key= HTTP/1.1\r\n\r\n")
        #expect(ctx.query["key"] == "")
        #expect(ctx.query.count == 1)
    }

    @Test("Empty key (`?=value`) is ignored")
    func emptyKeyIgnored() throws {
        let ctx = try parseRequest("GET /?=value HTTP/1.1\r\n\r\n")
        #expect(ctx.query[""] == nil)
        #expect(ctx.query.count == 0)
    }

    @Test("Multi-valued key returns first via subscript, all via values(for:)")
    func multiValued() throws {
        let ctx = try parseRequest(
            "GET /?id=1&id=2&id=3 HTTP/1.1\r\n\r\n"
        )
        #expect(ctx.query["id"] == "1")  // first
        #expect(ctx.query.values(for: "id") == ["1", "2", "3"])
        #expect(ctx.query.count == 3)
    }

    @Test("Consecutive separators (`?a=1&&b=2`) are skipped")
    func consecutiveSeparators() throws {
        let ctx = try parseRequest(
            "GET /?a=1&&b=2 HTTP/1.1\r\n\r\n"
        )
        #expect(ctx.query["a"] == "1")
        #expect(ctx.query["b"] == "2")
        #expect(ctx.query.count == 2)  // empty pair in the middle skipped
    }

    @Test("Trailing `&` is tolerated")
    func trailingAmpersand() throws {
        let ctx = try parseRequest(
            "GET /?a=1& HTTP/1.1\r\n\r\n"
        )
        #expect(ctx.query["a"] == "1")
        #expect(ctx.query.count == 1)
    }

    // MARK: - Case sensitivity

    @Test("Keys are case-sensitive")
    func caseSensitive() throws {
        let ctx = try parseRequest(
            "GET /?Foo=1&foo=2 HTTP/1.1\r\n\r\n"
        )
        #expect(ctx.query["Foo"] == "1")
        #expect(ctx.query["foo"] == "2")
        #expect(ctx.query["FOO"] == nil)
    }

    // MARK: - URL decoding

    @Test("Percent-encoded ASCII is decoded")
    func percentEncodedAscii() throws {
        // %2F = '/', %3A = ':', %40 = '@'
        let ctx = try parseRequest(
            "GET /u?path=%2Fusr%2Fbin%3A8000%40host HTTP/1.1\r\n\r\n"
        )
        #expect(ctx.query["path"] == "/usr/bin:8000@host")
    }

    @Test("Plus is decoded as space")
    func plusIsSpace() throws {
        let ctx = try parseRequest(
            "GET /search?q=hello+world HTTP/1.1\r\n\r\n"
        )
        #expect(ctx.query["q"] == "hello world")
    }

    @Test("Mixed percent-encoded and plus")
    func mixedEncoding() throws {
        // %2B = '+', literal + → space
        let ctx = try parseRequest(
            "GET /?s=a+b%2Bc HTTP/1.1\r\n\r\n"
        )
        #expect(ctx.query["s"] == "a b+c")
    }

    @Test("Invalid percent sequence keeps literal `%`")
    func invalidPercentSequence() throws {
        // %ZZ is not valid hex
        let ctx = try parseRequest(
            "GET /?v=100%ZZ HTTP/1.1\r\n\r\n"
        )
        #expect(ctx.query["v"] == "100%ZZ")
    }

    @Test("Truncated percent sequence keeps literal `%`")
    func truncatedPercent() throws {
        // %2 at end of string — not enough bytes for a full %XX
        let ctx = try parseRequest(
            "GET /?v=100%2 HTTP/1.1\r\n\r\n"
        )
        #expect(ctx.query["v"] == "100%2")
    }

    // MARK: - UTF-8 / Cyrillic

    @Test("Percent-encoded UTF-8 (Cyrillic)")
    func percentEncodedUtf8() throws {
        // Иван = 0xD0 0x98 0xD0 0xB2 0xD0 0xB0 0xD0 0xBD
        // %-encoded: %D0%98%D0%B2%D0%B0%D0%BD
        let ctx = try parseRequest(
            "GET /?name=%D0%98%D0%B2%D0%B0%D0%BD HTTP/1.1\r\n\r\n"
        )
        #expect(ctx.query["name"] == "Иван")
    }

    @Test("Raw UTF-8 bytes in query (non-RFC but seen in the wild)")
    func rawUtf8() throws {
        // curl and some clients send raw UTF-8 in the URL rather than
        // percent-encoding. RFC 3986 forbids this, but we accept it
        // (matches the WHATWG URL standard / browser behaviour).
        let ctx = try parseRequest(
            "GET /?name=Иван HTTP/1.1\r\n\r\n"
        )
        #expect(ctx.query["name"] == "Иван")
    }

    @Test("Cyrillic key")
    func cyrillicKey() throws {
        let ctx = try parseRequest(
            "GET /?пользователь=иван HTTP/1.1\r\n\r\n"
        )
        #expect(ctx.query["пользователь"] == "иван")
    }

    @Test("Emoji value")
    func emojiValue() throws {
        // 🚀 = U+1F680 = UTF-8 F0 9F 9A 80
        let ctx = try parseRequest(
            "GET /?e=%F0%9F%9A%80 HTTP/1.1\r\n\r\n"
        )
        #expect(ctx.query["e"] == "🚀")
    }

    // MARK: - forEachValue

    @Test("forEachValue iterates multi-valued key in order")
    func forEachValueOrder() throws {
        let ctx = try parseRequest(
            "GET /?tag=swift&tag=linux&tag=perf HTTP/1.1\r\n\r\n"
        )
        var collected: [String] = []
        ctx.query.forEachValue(of: "tag") { collected.append($0) }
        #expect(collected == ["swift", "linux", "perf"])
    }
}
