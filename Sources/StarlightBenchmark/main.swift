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
import Atomics
import NIOCore
import NIOPosix
import StarlightCore
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
    starlight-benchmark — Phase 0 TCP echo benchmark driver

    USAGE:
        starlight-benchmark [OPTIONS]

    OPTIONS:
        -h, --host <host>            Bind host (default: 0.0.0.0)
        -p, --port <port>            Bind port (default: 8080)
        -l, --loops <count>          Number of event loops (default: core count)
        -s, --stats-interval <sec>   Seconds between stats prints (0 = off, default: 5)
            --help                   Print this help and exit

    EXAMPLES:
        # Default: one loop per core on :8080
        starlight-benchmark

        # Drive load from a separate host
        wrk -t<cores> -c256 -d30s http://\(ProcessInfo.processInfo.hostName):8080/

    PHASE 0 NOTE:
        This is a TCP echo server, not an HTTP server. Use bench/tcp_echo.sh
        for TCP throughput; HTTP lands in Phase 2.

    SIGNALS:
        SIGINT / SIGTERM use the default disposition (process termination).
        The kernel closes listener sockets; the process exits without a
        graceful drain. Phase 4 will add signal-pipe-driven graceful shutdown.
    """)
}

//===----------------------------------------------------------------------===//
// Main — async, blocks until SIGINT/SIGTERM (default disposition)
//=========----------------------------------------------------------------------//

@main
struct StarlightBenchmark {
    static func main() async throws {
        let cli = parseArgs(CommandLine.arguments)
        let app = StarlightApp(loopCount: cli.loops)
        let server = app.server

        // Ignore SIGPIPE — writes to broken sockets return EPIPE, which
        // `EchoHandler.errorCaught` handles by closing the channel. A
        // SIGPIPE-induced termination would leak resources and kill the
        // whole server for one client's mistake.
        signal(SIGPIPE, SIG_IGN)

        out("""
        ╔══════════════════════════════════════════════════════════════════╗
        ║                  Starlight Phase 0 — TCP echo                   ║
        ╚══════════════════════════════════════════════════════════════════╝
        Configuration:
          Bind                : \(cli.host):\(cli.port)
          Event loops         : \(server.loopCount)  (= CPU cores, thread-per-core)
          SO_REUSEPORT        : enabled  (per-loop listener, kernel-balanced accept)
          Pipeline            : TCP echo  (sync ChannelHandler — zero Task allocs)
        """)

        // Bootstrap. Async to keep `main` canonical; under the hood it uses
        // `.wait()` once per listener since there is nothing useful to
        // overlap it with at startup. The interesting concurrency begins
        // *after* this returns: every accepted connection is handled
        // concurrently on its owning event loop.
        try await app.start(host: cli.host, port: cli.port)
        out("  Listeners           : \(server.listenerChannels.count)  (one per event loop)")
        out("  Status              : listening")
        out()
        out("Press Ctrl-C to stop.")

        // Stats printer task — runs concurrently on the global cooperative
        // pool. This is NOT a request hot path, so we don't pin it to an
        // event loop. Phase 2's HTTP hot path will live inside the sync
        // ChannelHandler pipeline (zero Task allocations per request).
        if cli.statsInterval > 0 {
            let interval = cli.statsInterval
            let stats = server.stats
            Task {
                while true {
                    try await Task.sleep(for: .seconds(interval))
                    let conns = stats.connectionsAccepted.load()
                    let rx = stats.bytesReceived.load()
                    let tx = stats.bytesSent.load()
                    out(String(format: "stats  conns=%-10lld  rx=%-12lld B  tx=%-12lld B", conns, rx, tx))
                }
            }
        }

        // Block this task forever. In Phase 0, SIGINT/SIGTERM use the
        // default disposition and the process terminates immediately — the
        // kernel closes listener sockets and the event loops wind down.
        //
        // We use a polling loop with `Task.sleep` rather than a single
        // infinite sleep because `Task.sleep(for: .seconds(.greatestFiniteMagnitude))`
        // overflows `Duration`'s internal attoseconds representation on
        // Linux and traps. A 1-hour sleep with a re-arm loop is simple and
        // avoids the overflow.
        while true {
            try await Task.sleep(for: .seconds(3600))
        }
    }
}
