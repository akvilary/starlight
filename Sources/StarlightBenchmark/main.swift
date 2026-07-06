//===----------------------------------------------------------------------===//
//
//  main.swift
//  StarlightBenchmark
//
//  Phase 0 benchmark driver. Boots a `StarlightServer` running the TCP echo
//  pipeline and prints periodic stats. The accompanying
//  `bench/wrk_plaintext.sh` script drives load against this server with wrk.
//
//  Design note: `main` is intentionally synchronous. It exists only to
//  bootstrap the process (parse args, install signal handlers, bind
//  listeners) and then block on `server.wait()` while event loops handle
//  connections concurrently. The synchronous surface area is bounded to
//  startup and shutdown; everything *inside* a connection — channel
//  handlers, future HTTP/1 codec, future async request processing — runs
//  concurrently on each connection's owning event loop.
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
// Signal handling
//===----------------------------------------------------------------------===//

/// Global stop flag, mutated only from the SIGINT handler and read by the
/// benchmark's main loop. Global so the signal-handler closure does not need
/// to capture state (which would prevent it from being converted to a C
/// function pointer).
let stopFlag = ManagedAtomic<Bool>(false)

@_cdecl("sl_handle_sigint")
fileprivate func sl_handle_sigint(_ sig: Int32) {
    _ = sig
    stopFlag.store(true, ordering: .sequentiallyConsistent)
}

//===----------------------------------------------------------------------===//
// Unbuffered output — direct `write(2)` via `FileHandle.write`
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
        This is a TCP echo server, not an HTTP server. wrk will still report
        throughput numbers because it measures bytes/requests at the TCP level;
        for a true plaintext HTTP benchmark, wait for Phase 2.
    """)
}

//===----------------------------------------------------------------------===//
// Main — synchronous bootstrap, then block on `server.wait()`
//===----------------------------------------------------------------------===//

@main
struct StarlightBenchmark {
    static func main() {
        let cli = parseArgs(CommandLine.arguments)
        let app = StarlightApp(loopCount: cli.loops)
        let server = app.server

        // Install signal handlers. SIGINT sets the atomic flag; the main
        // loop polls it and triggers shutdown. SIGPIPE is ignored (writes
        // to broken sockets return EPIPE which we handle in the pipeline).
        signal(SIGINT, sl_handle_sigint)
        signal(SIGPIPE, SIG_IGN)

        out("""
        ╔══════════════════════════════════════════════════════════════════╗
        ║                  Starlight Phase 0 — TCP echo                   ║
        ╚══════════════════════════════════════════════════════════════════╝
        Configuration:
          Bind                : \(cli.host):\(cli.port)
          Event loops         : \(server.loopCount)  (= CPU cores, thread-per-core)
          SO_REUSEPORT        : enabled  (per-loop listener, kernel-balanced accept)
          Pipeline            : TCP echo
        """)

        // Bootstrap synchronously. `try!` is safe here: a bind failure is a
        // fatal misconfiguration (port in use, wrong host) and there is no
        // useful recovery action for a benchmark driver.
        try! app.start(host: cli.host, port: cli.port)
        out("  Listeners           : \(server.listenerChannels.count)  (one per event loop)")
        out("  Status              : listening")
        out()

        // Stats printer (optional). Runs on a dedicated pthread — *not* on
        // any event loop, so it does not steal cycles from connection
        // processing. We avoid `Task { }` here because we want the stats
        // printer to work even before async machinery is wired up in the
        // connection hot path.
        if cli.statsInterval > 0 {
            let interval = cli.statsInterval
            let stats = server.stats
            Thread.detachNewThread {
                while !stopFlag.load(ordering: .relaxed) {
                    // Sleep `interval` seconds in 100 ms increments so we
                    // notice `stopFlag` quickly when shutting down.
                    var slept = 0
                    while slept < interval * 1000 && !stopFlag.load(ordering: .relaxed) {
                        usleep(100_000)
                        slept += 100
                    }
                    if stopFlag.load(ordering: .relaxed) { break }
                    let conns = stats.connectionsAccepted.load()
                    let rx = stats.bytesReceived.load()
                    let tx = stats.bytesSent.load()
                    out(String(format: "stats  conns=%-10lld  rx=%-12lld B  tx=%-12lld B", conns, rx, tx))
                }
            }
        }

        // Block main while event loops process connections. Poll the atomic
        // flag every 50 ms for responsive shutdown. (We do not block on
        // `channel.closeFuture.wait()` because we want SIGINT to drive
        // shutdown rather than waiting for an external channel close.)
        while !stopFlag.load(ordering: .relaxed) {
            usleep(50_000)
        }
        out()
        out("Shutting down…")

        // `try!` — a failure during shutdown of a benchmark driver is fatal.
        try! server.shutdown()
        out("Done.")
    }
}
