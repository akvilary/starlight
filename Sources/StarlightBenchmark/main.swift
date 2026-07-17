//===----------------------------------------------------------------------===//
//
//  main.swift
//  StarlightBenchmark
//
//  Phase 0 benchmark driver. Boots a `StarlightServer` running the TCP echo
//  pipeline and prints periodic stats.
//
//  Design note: `main` is async — canonical Swift Concurrency entry point.
//  It blocks the top-level task on a polling loop until SIGINT arrives.
//  Everything *inside* a connection — channel handlers, future HTTP/1
//  codec, future async request processing — runs concurrently on each
//  connection's owning event loop.
//
//  Signal handling: in Phase 0 we rely on the default SIGINT disposition
//  (process termination). The kernel closes listener sockets, the event
//  loops wind down, and the process exits. Graceful shutdown with proper
//  resource cleanup via a self-pipe / eventfd integration lands in a
//  later phase — see `bench/` and the roadmap.
//
//===----------------------------------------------------------------------===//

import Foundation
import NIOCore
import NIOPosix
import StarlightHTTP
import StarlightRouting
import StarlightServer
import Starlight

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

//===----------------------------------------------------------------------===//
// Output — unbuffered, direct `write(2)` via `FileHandle.write`
//===----------------------------------------------------------------------===//
//
// We bypass glibc's stdio buffering because the benchmark runs with its
// stdout attached to a pipe (background process, file redirect, live
// monitoring tool). Under that condition glibc fully buffers stdout, so
// `print()` output would not appear until process exit. `FileHandle.write`
// issues a raw `write(2)` syscall per call, which is unbuffered.
//
extension FileHandle {
    @inline(__always)
    func writeLine(_ s: String) {
        var bytes = Array(s.utf8)
        bytes.append(0x0A)
        self.write(Data(bytes))
    }
}

@inline(__always)
func out(_ s: String = "") {
    FileHandle.standardOutput.writeLine(s)
}

//===----------------------------------------------------------------------===//
// Argument parsing (intentionally tiny — no deps)
//===----------------------------------------------------------------------===//

struct CLI {
    var host: String = "0.0.0.0"
    var port: Int = 8080
    var loops: Int = System.coreCount
    var statsInterval: Int = 5   // seconds; 0 disables
    var mode: String = "echo"    // "echo", "http", or "router"
    #if os(Linux)
    var useIoUring: Bool = false // default: epoll (StarlightPoll)
    #endif
}

func parseArgs(_ args: [String]) -> CLI {
    var cli = CLI()
    var i = 1
    while i < args.count {
        let arg = args[i]
        func next() -> String? {
            i += 1
            return i < args.count ? args[i] : nil
        }
        switch arg {
        case "--host", "-h":
            if let v = next() { cli.host = v }
        case "--port", "-p":
            if let v = next(), let n = Int(v) { cli.port = n }
        case "--loops", "-l":
            if let v = next(), let n = Int(v) { cli.loops = n }
        case "--stats-interval", "-s":
            if let v = next(), let n = Int(v) { cli.statsInterval = n }
        case "--mode", "-m":
            if let v = next() { cli.mode = v }
        case "--io-uring":
            #if os(Linux)
            cli.useIoUring = true
            #else
            FileHandle.standardError.writeLine("--io-uring is only available on Linux")
            exit(2)
            #endif
        case "--help":
            printHelp()
            exit(0)
        default:
            FileHandle.standardError.writeLine("Unknown argument: \(arg)")
            exit(2)
        }
        i += 1
    }
    return cli
}

func printHelp() {
    out("""
    starlight-benchmark — Phase 2 benchmark driver

    USAGE:
        starlight-benchmark [OPTIONS]

    OPTIONS:
        -h, --host <host>            Bind host (default: 0.0.0.0)
        -p, --port <port>            Bind port (default: 8080)
        -l, --loops <count>          Number of event loops (default: core count)
        -s, --stats-interval <sec>   Seconds between stats prints (0 = off, default: 5)
        -m, --mode <echo|http|router>  Pipeline (default: echo)
            --io-uring               Use io_uring instead of epoll (Linux only)
            --help                   Print this help and exit

    EXAMPLES:
        # TCP echo (raw socket throughput):
        starlight-benchmark
        bench/tcp_echo.sh 127.0.0.1 8080 5 64 128

        # HTTP hello world (single handler, no routing):
        starlight-benchmark --mode http
        wrk -t<cores> -c256 -d10s http://127.0.0.1:8080/

        # HTTP with router (registers `/`, `/users/:id`, `/health`):
        starlight-benchmark --mode router
        wrk -t<cores> -c256 -d10s http://127.0.0.1:8080/users/42
    """)
}

//===----------------------------------------------------------------------===//
// Main — async, blocks until SIGINT/SIGTERM (default disposition)
//=========----------------------------------------------------------------------//

/// Pre-serialized HTTP response for the "Hello, World!" handler. Built
/// once at process startup so the per-request path does not allocate
/// any ByteBuffer — it just hands the cached buffer to NIO's write.
@Sendable
fileprivate func helloWorldHandler(_ ctx: borrowing RequestContext) -> HTTPResponse {
    _ = ctx
    return HTTPResponse(headerBuffer: StarlightBenchmark.helloResponse)
}

extension StarlightBenchmark {
    /// Cached "Hello, World!" response. We build it once at startup and
    /// hand the same buffer to every request. NIO's `ByteBuffer` is a
    /// COW value type, so `outbound.write(response.headerBuffer)` just bumps
    /// the storage's reference count without copying bytes. This
    /// eliminates the largest single allocation in the HTTP hot path.
    static let helloResponse: ByteBuffer = {
        var buf = ByteBufferAllocator().buffer(capacity: 256)
        buf.writeString("HTTP/1.1 200 OK\r\n")
        buf.writeString("Content-Type: text/plain; charset=utf-8\r\n")
        buf.writeString("Content-Length: 14\r\n")
        buf.writeString("Connection: keep-alive\r\n")
        buf.writeString("\r\n")
        buf.writeString("Hello, World!\n")
        return buf
    }()
}

/// Build a router with three routes for the `--mode router` benchmark.
/// This exercises the routing + path-param capture path on every request
/// rather than the single-handler short-circuit.
///
/// Static routes (`/`, `/health`) return **pre-cached** `ByteBuffer`s —
/// zero per-request allocation. ByteBuffer is COW, so each
/// `outbound.write(response.headerBuffer)` just bumps the shared storage's
/// reference count — no memcpy, no new heap allocation.
/// The dynamic route (`/users/:id`) necessarily allocates per request
/// (response depends on the captured id); it is the worst case.
func makeBenchmarkRouter() -> Router {
    // Pre-serialize the static responses once at startup so the
    // static routes (`/`, `/health`) don't allocate per request.
    let rootBytes = Array("""
        HTTP/1.1 200 OK\r\n\
        Content-Type: text/plain; charset=utf-8\r\n\
        Content-Length: 14\r\n\
        Connection: keep-alive\r\n\
        \r\n\
        Hello, World!\n
        """.utf8)
    let healthBytes = Array("""
        HTTP/1.1 200 OK\r\n\
        Content-Type: text/plain; charset=utf-8\r\n\
        Content-Length: 3\r\n\
        Connection: keep-alive\r\n\
        \r\n\
        ok\n
        """.utf8)

    var rootBuf = ByteBufferAllocator().buffer(capacity: rootBytes.count)
    rootBuf.writeBytes(rootBytes)
    var healthBuf = ByteBufferAllocator().buffer(capacity: healthBytes.count)
    healthBuf.writeBytes(healthBytes)

    // `let` bindings so the @Sendable handler closures can capture
    // them without strict-concurrency complaints. ByteBuffer is COW so
    // sharing the value across connections is cheap — the server
    // writes `response.headerBuffer` directly to the channel without copying.
    let rootBufLet = rootBuf
    let healthBufLet = healthBuf

    let builder = RouterBuilder()
    builder.get("/") { _ in
        HTTPResponse(headerBuffer: rootBufLet)
    }
    builder.get("/health") { _ in
        HTTPResponse(headerBuffer: healthBufLet)
    }
    builder.get("/users/:id") { ctx in
        // Dynamic route — response depends on the captured id. This
        // necessarily allocates per request.
        let id = ctx.params["id"] ?? "?"
        return HTTPResponse.plaintext("user \(id)\n")
    }
    // Async route — exercises the io_uring async dispatch path.
    builder.get("/async") { ctx async in
        return HTTPResponse.plaintext("async ok\n")
    }
    return builder.build()
}

@main
struct StarlightBenchmark {
    static func main() async throws {
        let cli = parseArgs(CommandLine.arguments)
        let app = StarlightApp(loopCount: cli.loops)
        let server = app.server

        signal(SIGPIPE, SIG_IGN)

        // Default backend per platform. On Linux the default is now
        // StarlightPoll (epoll) — the same primitive mio/tokio use,
        // production-proven and container-friendly. io_uring is opt-in
        // via `--io-uring`. NIO is the macOS primary and Linux
        // last-resort fallback.
        #if os(Linux)
        let backendName = cli.useIoUring ? "io_uring" : "epoll"
        #else
        let backendName = "NIOAsyncChannel"
        #endif

        out("""
        ╔══════════════════════════════════════════════════════════════════╗
        ║         Starlight Phase 4 — \(cli.mode.uppercased()) (\(backendName))          ║
        ╚══════════════════════════════════════════════════════════════════╝
        Configuration:
          Bind                : \(cli.host):\(cli.port)
          Event loops         : \(server.loopCount)  (= CPU cores, thread-per-core)
          SO_REUSEPORT        : enabled  (per-loop listener, kernel-balanced accept)
          Architecture        : \(backendName) (thread-per-core)
          Pipeline            : \(cli.mode == "http" ? "HTTP/1.1 hello world" : cli.mode == "router" ? "HTTP/1.1 router" : "TCP echo")
        """)
        out("  Status              : starting…")
        out()

        // Stats printer — runs on a dedicated pthread (NOT a request
        // hot path). `server.start()` blocks, so the stats thread
        // must be started before it.
        if cli.statsInterval > 0 {
            let interval = cli.statsInterval
            let stats = server.stats
            Thread.detachNewThread {
                while true {
                    var slept = 0
                    while slept < interval * 1_000_000 {
                        usleep(100_000)
                        slept += 100_000
                    }
                    let conns = stats.connectionsAccepted.load()
                    let rx = stats.bytesReceived.load()
                    let tx = stats.bytesSent.load()
                    out(String(format: "stats  conns=%-10lld  rx=%-12lld B  tx=%-12lld B", conns, rx, tx))
                }
            }
        }

        let mode: Mode = (cli.mode == "echo") ? .tcpEcho : .http
        let helloHandler: HTTPHandler? = (cli.mode == "http") ? helloWorldHandler : nil
        let httpHandler = helloHandler
        let router: Router? = (cli.mode == "router") ? makeBenchmarkRouter() : nil

        // `start()` blocks until shutdown (SIGINT terminates the
        // process; the kernel closes listeners and the discarding
        // task group drains).
        #if os(Linux)
        try await server.start(
            host: cli.host,
            port: cli.port,
            mode: mode,
            httpHandler: httpHandler,
            router: router,
            linuxBackend: cli.useIoUring ? .ioUring : .epoll
        )
        #else
        try await server.start(
            host: cli.host,
            port: cli.port,
            mode: mode,
            httpHandler: httpHandler,
            router: router
        )
        #endif
    }
}
