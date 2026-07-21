//===----------------------------------------------------------------------===//
//
//  main.swift
//  HelloWorld
//
//  Smoke test: spin up the server on port 8080 with a minimal
//  Service, install SIGINT/SIGTERM handlers, and run with graceful
//  shutdown.
//
//      swift run hello-world
//      curl http://localhost:8080/
//      # stop with Ctrl-C — server drains in-flight requests
//
//===----------------------------------------------------------------------===//

import Starlight
import StarlightServer
import StarlightTower
import HTTP

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
print("Press Ctrl-C to shut down gracefully")

// Install SIGINT/SIGTERM handlers BEFORE serve() so we don't race
// with the signal arriving during startup.
installShutdownSignalHandlers()

try await serve(
    HelloService(),
    on: "0.0.0.0", port: port,
    onShutdown: {
        // This closure returns when SIGINT/SIGTERM is received.
        // serve() then drains in-flight requests (up to 30s) and exits.
        print("\nShutdown signal received — draining...")
        await waitForShutdownSignal()
    }
)

#if canImport(Glibc)
import Glibc
#endif

print("Server stopped cleanly.")
Glibc.exit(0)
