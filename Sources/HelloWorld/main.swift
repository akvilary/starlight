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

// MARK: - Application service

struct AppService: Service {
    typealias Request = HTTP.Request<Body>
    typealias Response = HTTP.Response<Body>

    func call(_ request: consuming HTTP.Request<Body>) async throws -> HTTP.Response<Body> {
        switch (request.method, request.uri.pathString) {
        case (.GET, "/"):
            // Buffered body — most common case.
            return .plain("Hello, World!\n")

        case (.GET, "/health"):
            // JSON response (manual construction).
            let json = """
            {"status":"ok","uptime":"running"}
            """
            var headers = HeaderMap()
            headers.insert(.contentType, "application/json; charset=utf-8")
            headers.insert(.contentLength, String(json.utf8.count))
            return HTTP.Response<Body>(
                status: .ok, headers: headers, body: .buffered(Array(json.utf8))
            )

        case (.GET, "/stream"):
            // Streaming body — SSE endpoint.
            return .stream(
                SSESource(eventCount: 5, intervalMs: 500),
                status: .ok,
                contentType: "text/event-stream"
            )

        default:
            // 404 for unknown paths.
            return .plain(
                "404 Not Found: \(request.method) \(request.uri.pathString)\n",
                status: .notFound
            )
        }
    }
}

// MARK: - Main

let args = CommandLine.arguments
let port = args.count > 1 ? Int(args[1]) ?? 8080 : 8080

print("""
Starlight HTTP server listening on http://0.0.0.0:\(port)

  GET /         — buffered 'Hello, World!'
  GET /health   — JSON health check
  GET /stream   — SSE stream (chunked TE)
  GET /unknown  — 404 Not Found

Middleware: TraceLayer (request logging) + TimeoutLayer (30s cap)
Press Ctrl-C to shut down gracefully
""")

installShutdownSignalHandlers()

// Middleware is available but NOT applied by default — each layer
// adds per-request overhead (closure indirection, and for TimeoutLayer
// a task-group race). Apply selectively where needed:
//
//   let app = ServiceBuilder<HTTP.Request<Body>, HTTP.Response<Body>>()
//       .layer(TraceLayer(config: .stderr).asLayer())  // request logging
//       .layer(TimeoutLayer(duration: .seconds(30)).asLayer())  // slow-loris defence
//       .layer(CorsLayer().asLayer())  // browser CORS
//       .service(AppService())
//
// For maximum throughput (260K+ req/s) serve the raw service:

try await serve(
    AppService(),
    on: "0.0.0.0", port: port,
    onShutdown: { await waitForShutdownSignal() }
)

print("Server stopped cleanly.")
Glibc.exit(0)
