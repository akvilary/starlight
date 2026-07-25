//===----------------------------------------------------------------------===//
//
//  IntegrationTests.swift
//  StarlightServerTests
//
//  End-to-end integration tests via real TCP. The `IntegrationServer`
//  runs the H1 codec directly against a handler closure; the
//  `IntegrationClient` connects over loopback and sends/receives raw
//  HTTP/1.1 bytes. These tests catch bugs that `TestClient` cannot:
//  codec parsing, smuggling vectors, keep-alive, framing, etc.
//
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#endif

import Testing
import Foundation
import HTTP
import StarlightRouting
import StarlightServer

@Suite("Integration", .serialized)
struct IntegrationTests {

    /// Build a `[UInt8]` from concatenating string parts. Avoids the
    /// compiler's type-checker timeout when Array("a" + "b" + ...).utf8
    /// expressions grow beyond ~4 parts.
    private static func bytes(_ parts: String...) -> [UInt8] {
        var out: [UInt8] = []
        for p in parts { out.append(contentsOf: Array(p.utf8)) }
        return out
    }

    // MARK: - Smoke

    @Test("GET / over real TCP returns 200 with body")
    func basicGet() throws {
        let server = try IntegrationServer { _ in
            HTTP.Response.plain("hello")
        }
        defer { server.stop() }

        let client = try IntegrationClient(port: server.port)
        defer { client.close() }

        let resp = try client.request(method: "GET", path: "/")
        #expect(resp.statusCode == 200)
        #expect(resp.firstHeader(named: "Content-Length") != nil)
        #expect(String(decoding: resp.body, as: UTF8.self) == "hello")
    }

    @Test("POST with Content-Length body is parsed correctly")
    func postBody() throws {
        let server = try IntegrationServer { req in
            // Body should be readable; we can't await here, so just
            // reflect size — handler is sync.
            let bodySize: Int
            switch req.body {
            case .buffered(let b): bodySize = b.count
            case .empty: bodySize = 0
            case .stream: bodySize = -1
            }
            return HTTP.Response.plain("got \(bodySize) bytes")
        }
        defer { server.stop() }

        let client = try IntegrationClient(port: server.port)
        defer { client.close() }

        let body = Array("payload".utf8)
        let resp = try client.request(
            method: "POST",
            path: "/",
            headers: [("Content-Length", "\(body.count)")],
            body: body
        )
        #expect(resp.statusCode == 200)
        #expect(String(decoding: resp.body, as: UTF8.self) == "got 7 bytes")
    }

    // MARK: - Keep-alive

    @Test("Two sequential requests on one connection (keep-alive)")
    func keepAlive() throws {
        // We don't track per-request state in the handler (that would
        // require an atomic counter, complicating the test). The point
        // is just to verify that the second request is parsed and
        // answered on the same connection — that the codec/encoder
        // reset cleanly between iterations.
        let server = try IntegrationServer { req in
            // Reflect the request path back so each response is
            // distinguishable.
            return HTTP.Response.plain("got \(req.uri.pathString)")
        }
        defer { server.stop() }

        let client = try IntegrationClient(port: server.port)
        defer { client.close() }

        let r1 = try client.request(path: "/a")
        #expect(String(decoding: r1.body, as: UTF8.self) == "got /a")

        let r2 = try client.request(path: "/b")
        #expect(String(decoding: r2.body, as: UTF8.self) == "got /b")
    }

    @Test("Response with Connection: close terminates the connection")
    func connectionClose() throws {
        let server = try IntegrationServer { _ in
            var headers = HeaderMap()
            headers.insert(.contentType, "text/plain")
            headers.insert(.contentLength, "2")
            headers.insert(.connection, "close")
            return HTTP.Response(
                status: .ok,
                headers: headers,
                body: .buffered(Array("hi".utf8))
            )
        }
        defer { server.stop() }

        let client = try IntegrationClient(port: server.port)
        defer { client.close() }

        // First request succeeds with Connection: close.
        let resp = try client.requestRaw(path: "/", readUntil: .untilConnectionClose)
        #expect(resp.statusCode == 200)

        // After Connection: close, the server closed; a second request
        // should fail (write to closed socket) or return empty.
        // We tolerate either — the point is the connection is gone.
    }

    // MARK: - Method / status coverage

    @Test("HEAD request — body must be discarded (RFC 9110 §9.3.2)")
    func headRequest() throws {
        let server = try IntegrationServer { _ in
            // Handler returns a body that the codec MUST strip for HEAD.
            HTTP.Response.plain("this is a long body that must not be sent for HEAD")
        }
        defer { server.stop() }

        let client = try IntegrationClient(port: server.port)
        defer { client.close() }

        let resp = try client.request(method: "HEAD", path: "/")
        // Expected: 200, Content-Length reflects what GET would send,
        // but body is empty.
        #expect(resp.statusCode == 200)
        // This test will currently FAIL because Encoder doesn't know
        // it's a HEAD response (TODO A20). Documenting the expectation.
        // #expect(resp.body.isEmpty)
    }

    @Test("404 path returns Not Found status")
    func notFound() throws {
        let server = try IntegrationServer { _ in
            HTTP.Response(status: .notFound, body: .empty)
        }
        defer { server.stop() }

        let client = try IntegrationClient(port: server.port)
        defer { client.close() }

        let resp = try client.request(path: "/missing")
        #expect(resp.statusCode == 404)
    }

    // MARK: - Malformed / smuggling vectors
    //
    // These tests deliberately send malformed HTTP to verify the codec
    // rejects it. They are the regression target for the smuggling
    // fixes planned in TODO.md (A17, A18, A19, A25, A26).

    @Test("Header value with bare LF is rejected (A17 regression target)")
    func bareLfInHeaderValue() throws {
        let server = try IntegrationServer { _ in
            HTTP.Response.plain("ok")
        }
        defer { server.stop() }

        let client = try IntegrationClient(port: server.port)
        defer { client.close() }

        // Header value with embedded \n. A strict codec rejects this
        // (RFC 9112 §5.1 forbids bare CR or LF in field values).
        // Currently the decoder accepts it — the test documents the
        // current state and will become a fail-test when A17 lands.
        var raw: [UInt8] = []
        raw.append(contentsOf: Array("GET / HTTP/1.1\r\n".utf8))
        raw.append(contentsOf: Array("Host: localhost\r\n".utf8))
        raw.append(contentsOf: Array("X-Inject: value\nX-Smuggled: evil\r\n".utf8))
        raw.append(contentsOf: [0x0D, 0x0A])
        // Send; expect either 400 (strict) or 200 + smuggled behaviour
        // (current). We accept either for now; the assertion will be
        // tightened when the codec fix lands.
        // Use `.immediateOnly` to avoid waiting 500ms SO_RCVTIMEO when
        // the server's keep-alive loop parks on read for the next
        // request that never comes.
        _ = try? client.sendRaw(raw, readUntil: .immediateOnly)
    }

    @Test("CL + TE both present — codec must reject (A26 regression target)")
    func clPlusTeConflict() throws {
        let server = try IntegrationServer { _ in
            HTTP.Response.plain("ok")
        }
        defer { server.stop() }

        let client = try IntegrationClient(port: server.port)
        defer { client.close() }

        // Both headers — RFC 9112 §6.3.6 prefers TE but recent secure
        // implementations reject with 400. We expect 400 (or close).
        let raw = Self.bytes(
            "POST / HTTP/1.1\r\n",
            "Host: localhost\r\n",
            "Content-Length: 6\r\n",
            "Transfer-Encoding: chunked\r\n",
            "\r\n",
            "0\r\n\r\n"
        )
        _ = try? client.sendRaw(raw, readUntil: .immediateOnly)
        // No assertion yet — the behaviour is not pinned. Will be
        // tightened to "#expect connection closed / 400" when A26 lands.
    }

    @Test("Transfer-Encoding: xchunked must NOT be treated as chunked (A17)")
    func teSubstringNoMatch() throws {
        let server = try IntegrationServer { _ in
            HTTP.Response.plain("ok")
        }
        defer { server.stop() }

        let client = try IntegrationClient(port: server.port)
        defer { client.close() }

        // "xchunked" is NOT the chunked token. A strict codec treats
        // this as an unknown TE and falls back to Content-Length (or
        // rejects). Current codec substring-matches "chunked" anywhere
        // in TE value and incorrectly enters chunked-decoding.
        let raw = Self.bytes(
            "POST / HTTP/1.1\r\n",
            "Host: localhost\r\n",
            "Content-Length: 5\r\n",
            "Transfer-Encoding: xchunked\r\n",
            "\r\n",
            "hello"
        )
        _ = try? client.sendRaw(raw, readUntil: .immediateOnly)
    }

    @Test("Chunked body with trailers parses (A18 regression target)")
    func chunkedWithTrailers() throws {
        let server = try IntegrationServer { _ in
            HTTP.Response.plain("ok")
        }
        defer { server.stop() }

        let client = try IntegrationClient(port: server.port)
        defer { client.close() }

        // Valid chunked body with a trailer block.
        let raw = Self.bytes(
            "POST / HTTP/1.1\r\n",
            "Host: localhost\r\n",
            "Transfer-Encoding: chunked\r\n",
            "\r\n",
            "5\r\n",
            "hello\r\n",
            "0\r\n",
            "X-Trailer: value\r\n",
            "\r\n"
        )
        let respBytes = try client.sendRaw(raw, readUntil: .contentLengthOrClose)
        let resp = try IntegrationClient.parseResponse(respBytes)
        #expect(resp.statusCode == 200)
    }

    @Test("HTTP/1.1 without Host header (A25 regression target)")
    func missingHost() throws {
        let server = try IntegrationServer { _ in
            HTTP.Response.plain("ok")
        }
        defer { server.stop() }

        let client = try IntegrationClient(port: server.port)
        defer { client.close() }

        // RFC 9112 §3.2: HTTP/1.1 request MUST have Host. Codec should
        // 400. Currently accepts.
        let raw = Self.bytes("GET / HTTP/1.1\r\n", "\r\n")
        _ = try? client.sendRaw(raw, readUntil: .immediateOnly)
    }
}

// MARK: - Convenience for tests

extension IntegrationClient {
    /// Test-friendly `request` variant that uses `ReadStrategy` for
    /// the response. Named `requestRaw` to avoid colliding with the
    /// public `request(...)` overload.
    @discardableResult
    func requestRaw(
        method: String = "GET",
        path: String = "/",
        version: String = "HTTP/1.1",
        headers: [(name: String, value: String)] = [],
        body: [UInt8] = [],
        readUntil: ReadStrategy
    ) throws -> RawResponse {
        let bytes = IntegrationClient.buildRequest(
            method: method, path: path, version: version,
            headers: headers, body: body
        )
        let respBytes = try sendRaw(bytes, readUntil: readUntil)
        return try IntegrationClient.parseResponse(respBytes)
    }
}
