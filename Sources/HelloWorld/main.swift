//===----------------------------------------------------------------------===//
//
//  main.swift
//  HelloWorld
//
//  Smoke test: spin up the server on port 8080 with a minimal
//  Service that responds "Hello, World!" to any path.
//
//      swift run hello-world
//      curl -v http://localhost:8080/
//
//===----------------------------------------------------------------------===//

import Starlight
import StarlightTower
import HTTP

/// Trivial Service — responds 200 OK with "Hello, World!" to every
/// request. Demonstrates the minimum API surface.
struct HelloService: Service {
    typealias Request = HTTP.Request<Body>
    typealias Response = HTTP.Response<Body>

    func call(_ request: consuming HTTP.Request<Body>) async throws -> HTTP.Response<Body> {
        return .plain("Hello, World!\n")
    }
}

let args = CommandLine.arguments
let port = args.count > 1 ? Int(args[1]) ?? 8080 : 8080

print("Listening on http://0.0.0.0:\(port)")
try await serve(HelloService(), on: "0.0.0.0", port: port)
