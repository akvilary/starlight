//===----------------------------------------------------------------------===//
//
//  main.swift
//  HelloWorld
//
//  Smoke test: spin up the server on port 8080 with two endpoints:
//    /        — plain "Hello, World!" (buffered body)
//    /stream  — Server-Sent Events stream (streaming body via chunked TE)
//
//      swift run hello-world
//      curl http://localhost:8080/
//      curl -N http://localhost:8080/stream
//
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#endif

import Foundation
import Starlight
import StarlightServer
import StarlightTower
import HTTP
import Hyper

/// SSE chunk source — produces 5 events, one per second.
/// Each event is `data: message-N\n\n` (Server-Sent Events format).
struct SSESource: AsyncSequence, Sendable {
    typealias Element = [UInt8]
    typealias AsyncIterator = SSEIterator

    var eventCount: Int
    var intervalMs: UInt64

    func makeAsyncIterator() -> SSEIterator {
        SSEIterator(eventCount: eventCount, intervalMs: intervalMs)
    }

    struct SSEIterator: AsyncIteratorProtocol {
        var eventCount: Int
        var intervalMs: UInt64
        var index: Int = 0

        mutating func next() async throws -> [UInt8]? {
            guard index < eventCount else { return nil }
            index += 1
            // Sleep between events — simulates real-world SSE.
            if index > 1 {
                try? await Task.sleep(for: .milliseconds(Int(intervalMs)))
            }
            let payload = "data: message-\(index)\n\n"
            return Array(payload.utf8)
        }
    }
}

struct HelloService: Service {
    typealias Request = HTTP.Request<Body>
    typealias Response = HTTP.Response<Body>

    func call(_ request: consuming HTTP.Request<Body>) async throws -> HTTP.Response<Body> {
        switch request.uri.pathString {
        case "/":
            // Buffered body — most common case.
            return .plain("Hello, World!\n")

        case "/stream":
            // Streaming body — SSE endpoint.
            // `Body.stream(...)` + `Response.stream(...)` produces:
            //   HTTP/1.1 200 OK\r\n
            //   Transfer-Encoding: chunked\r\n
            //   Content-Type: text/event-stream\r\n
            //   \r\n
            //   <hex-len>\r\n<data: message-N\n\n>\r\n
            //   ...
            //   0\r\n\r\n
            return .stream(
                SSESource(eventCount: 5, intervalMs: 500),
                status: .ok,
                contentType: "text/event-stream"
            )

        default:
            return .plain("Not Found", status: .notFound)
        }
    }
}

let args = CommandLine.arguments
let port = args.count > 1 ? Int(args[1]) ?? 8080 : 8080

print("Listening on http://0.0.0.0:\(port)")
print("  GET /         — buffered 'Hello, World!'")
print("  GET /stream   — SSE stream of 5 messages (chunked TE)")
print("Press Ctrl-C to shut down gracefully")

installShutdownSignalHandlers()

try await serve(
    HelloService(),
    on: "0.0.0.0", port: port,
    onShutdown: { await waitForShutdownSignal() }
)

print("Server stopped cleanly.")
Glibc.exit(0)
