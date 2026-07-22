//===----------------------------------------------------------------------===//
//
//  main.swift
//  HelloWorld
//
//  Comprehensive example demonstrating:
//    • Multiple routes (GET /, GET /health, GET /stream)
//    • Middleware composition (TraceLayer + TimeoutLayer)
//    • JSON responses
//    • Streaming bodies (SSE via chunked TE)
//    • 404 fallback
//    • Graceful shutdown
//
//      swift run -c release hello-world
//      curl http://localhost:8080/
//      curl http://localhost:8080/health
//      curl http://localhost:8080/stream -N
//      curl http://localhost:8080/unknown
//
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#endif

import Foundation
import Starlight
import StarlightServer
import StarlightMiddleware
import StarlightTower
import HTTP
import Hyper

// MARK: - SSE chunk source

struct SSESource: AsyncSequence, Sendable {
    typealias Element = [UInt8]
    var eventCount: Int
    var intervalMs: Int

    func makeAsyncIterator() -> Iterator {
        Iterator(eventCount: eventCount, intervalMs: intervalMs)
    }

    struct Iterator: AsyncIteratorProtocol {
        var eventCount: Int
        var intervalMs: Int
        var index = 0

        mutating func next() async throws -> [UInt8]? {
            guard index < eventCount else { return nil }
            index += 1
            if index > 1 {
                try? await Task.sleep(for: .milliseconds(intervalMs))
            }
            return Array("data: message-\(index)\n\n".utf8)
        }
    }
}

// MARK: - Application

// Build a Router with axum-style handler closures — no BoxService wrapping needed.
let app = Router(state: NoState())
    .get("/") { _ in
        // GET / — buffered body
        .plain("Hello, World!\n")
    }
    .get("/health") {
        // GET /health — JSON response
        let json = #"{"status":"ok","uptime":"running"}"#
        var headers = HeaderMap()
        headers.insert(.contentType, "application/json; charset=utf-8")
        headers.insert(.contentLength, String(json.utf8.count))
        return HTTP.Response(
            status: .ok, headers: headers, body: .buffered(Array(json.utf8))
        )
    }
    .get("/old") {
        // GET /old — redirect
        Redirect.to("/").intoResponse()
    }
    .get("/stream") { _ in
        // GET /stream — SSE streaming body
        .stream(
            SSESource(eventCount: 5, intervalMs: 500),
            status: .ok,
            contentType: "text/event-stream"
        )
    }

// MARK: - Main

let args = CommandLine.arguments
let port = args.count > 1 ? Int(args[1]) ?? 8080 : 8080

print("""
Starlight HTTP server listening on http://0.0.0.0:\(port)

  GET /         — buffered 'Hello, World!'
  GET /health   — JSON health check
  GET /old      — 302 redirect to /
  GET /stream   — SSE stream (chunked TE)
  GET /unknown  — 404 Not Found

Press Ctrl-C to shut down gracefully
""")

installShutdownSignalHandlers()

try await serve(
    app,
    on: "0.0.0.0", port: port,
    onShutdown: { await waitForShutdownSignal() }
)

print("Server stopped cleanly.")
Glibc.exit(0)
