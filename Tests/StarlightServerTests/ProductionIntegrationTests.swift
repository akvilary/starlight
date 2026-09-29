//===----------------------------------------------------------------------===//
//
//  ProductionIntegrationTests.swift
//  StarlightServerTests
//
//  End-to-end tests through the PRODUCTION stack: `serve()` + worker
//  threads + PollEventLoop + H1Conn. Complements `IntegrationTests`
//  (which uses the minimal inline-parser server for wire-level
//  vectors) with tests that need real streaming, lazy body pulls and
//  connection lifecycle.
//
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#endif

import Foundation
import Testing
import HTTPModel
import HTTPPrism
import StarlightCore
import StarlightExtractors
import StarlightRouting
import StarlightServer

/// A production `serve()` instance bound to an ephemeral-ish local
/// port, stoppable from the test.
final class ProductionServer: @unchecked Sendable {
    let port: Int
    private let continuation: AsyncStream<Void>.Continuation
    private let task: Task<Void, Error>

    init(service: some HTTPService) async throws {
        var lastError: Error? = nil
        var started = false
        var port = 0
        var continuation: AsyncStream<Void>.Continuation!
        var task: Task<Void, Error>!

        for _ in 0..<10 where !started {
            port = 20000 + Int.random(in: 0..<20000)
            let chosenPort = port
            let (stream, cont) = AsyncStream<Void>.makeStream()
            let onShutdown: @Sendable () async -> Void = { for await _ in stream {} }
            // Erase up-front so the Task captures a concrete Sendable.
            let boxed = BoxService(service)
            // Non-blocking completion/error reporter — awaiting the
            // Task's result here would deadlock (serve only returns
            // after shutdown), so the readiness loop polls this flag
            // instead. Bind failures surface through it.
            let status = RunStatus()
            let candidate = Task<Void, Error> { @Sendable in
                do {
                    try await Self.run(
                        boxed: boxed, port: chosenPort, onShutdown: onShutdown
                    )
                } catch {
                    status.fail(error)
                }
            }
            // Give the bind a moment; a bind failure surfaces as an
            // early error flag, otherwise wait for the port to accept.
            for _ in 0..<100 {
                if status.error != nil { break }
                if ProductionServer.probe(port: port) { started = true; break }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            if started {
                continuation = cont
                task = candidate
            } else {
                cont.finish()
                lastError = status.error ?? ProductionServerProbeError.couldNotBind
            }
        }
        guard started else { throw lastError ?? ProductionServerProbeError.couldNotBind }
        self.port = port
        self.continuation = continuation
        self.task = task
    }

    /// Trigger graceful shutdown and wait for `serve()` to return.
    func stop() async {
        continuation.finish()
        _ = try? await task.result
    }

    /// Isolated runner so the Task closure captures only trivially
    /// Sendable values (keeps SE-0466 region checking happy).
    private static func run(
        boxed: BoxService<HTTPModel.Request, HTTPModel.Response>,
        port: Int,
        onShutdown: @escaping @Sendable () async -> Void
    ) async throws {
        try await StarlightServer.serve(
            host: "127.0.0.1",
            port: port,
            service: boxed,
            loopCount: 1,
            drainTimeout: .seconds(5),
            onShutdown: onShutdown
        )
    }

    /// TCP connect probe — true once the listener accepts.
    private static func probe(port: Int) -> Bool {
        #if canImport(Glibc)
        let fd = Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { return false }
        defer { _ = Glibc.close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Glibc.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return rc == 0
        #else
        return false
        #endif
    }
}

private enum ProductionServerProbeError: Error {
    case couldNotBind
}

/// Non-blocking completion reporter for the serve task. A Mutex-held
/// optional error — written once by the serve task, polled by the
/// readiness loop (awaiting `Task.result` would deadlock).
private final class RunStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var _error: Error?

    var error: Error? {
        lock.lock(); defer { lock.unlock() }
        return _error
    }

    func fail(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        _error = error
    }
}

@Suite("Production integration", .serialized)
struct ProductionIntegrationTests {

    // MARK: - Body limits (C7 regression)

    @Test("Content-Length above the 2 MiB limit → 413 (head-parse path)")
    func contentLengthOverLimit() async throws {
        let router = Router()
            .post("/upload") { (_: HTTPModel.Request) in .plain("impossible") }
        let server = try await ProductionServer(service: router)
        defer { Task { await server.stop() } }

        let client = try IntegrationClient(port: server.port)
        defer { client.close() }

        // Claim a huge body but send only a fragment — the head-parse
        // CL check fires before any body byte is needed.
        let raw = Self.bytes(
            "POST /upload HTTP/1.1\r\n", "Host: localhost\r\n",
            "Content-Length: \(2 * 1024 * 1024 + 1000)\r\n",
            "\r\n", "partial"
        )
        let respBytes = try client.sendRaw(raw, readUntil: .immediateOnly)
        let resp = try IntegrationClient.parseResponse(respBytes)
        #expect(resp.statusCode == 413, "oversized Content-Length must yield 413, got \(resp.statusCode)")
    }

    @Test("Chunked body overrunning the codec limit → 413 via BodyError mapping (pull path)")
    func chunkedOverLimitThroughConsumingHandler() async throws {
        // The handler raises the extractor limit far above the codec's
        // 2 MiB max, so the overrun is detected by H1Conn's running
        // total inside the body pull — the exact path where the
        // H1ConnError → BodyError.limitExceeded mapping lives.
        let router = Router()
            .post("/upload") { (request: HTTPModel.Request) in
                let bytes = try await Bytes.fromRequest(request, state: NoState())
                return .plain("\(bytes.value.count)")
            }
            .layer(errorLayer())
            .layer(DefaultBodyLimit.layer(.init(maxBytes: 64 * 1024 * 1024)))
        let server = try await ProductionServer(service: router)
        defer { Task { await server.stop() } }

        let client = try IntegrationClient(port: server.port)
        defer { client.close() }

        var raw: [UInt8] = Self.bytes(
            "POST /upload HTTP/1.1\r\n", "Host: localhost\r\n",
            "Transfer-Encoding: chunked\r\n", "\r\n"
        )
        let chunk = [UInt8](repeating: 0x61, count: 1024 * 1024)  // 1 MiB
        for _ in 0..<3 {  // 3 MiB total — overruns the 2 MiB codec limit
            raw.append(contentsOf: Array("100000\r\n".utf8))
            raw.append(contentsOf: chunk)
            raw.append(contentsOf: [0x0D, 0x0A])
        }
        raw.append(contentsOf: Array("0\r\n\r\n".utf8))

        let respBytes = try client.sendRaw(raw, readUntil: .immediateOnly)
        let resp = try IntegrationClient.parseResponse(respBytes)
        #expect(resp.statusCode == 413, "mid-stream body overrun must surface as 413, got \(resp.statusCode)")
    }

    @Test("Normal POST through the production server still works")
    func normalPostRoundTrip() async throws {
        let router = Router()
            .post("/echo") { (request: HTTPModel.Request) in
                let bytes = try await Bytes.fromRequest(request, state: NoState())
                return .plain(String(decoding: bytes.value, as: UTF8.self))
            }
        let server = try await ProductionServer(service: router)
        defer { Task { await server.stop() } }

        let client = try IntegrationClient(port: server.port)
        defer { client.close() }

        let body = Array("ping".utf8)
        let resp = try client.request(
            method: "POST", path: "/echo",
            headers: [("Content-Length", "\(body.count)"), ("Content-Type", "application/octet-stream")],
            body: body
        )
        #expect(resp.statusCode == 200)
        #expect(String(decoding: resp.body, as: UTF8.self) == "ping")
    }

    private static func bytes(_ parts: String...) -> [UInt8] {
        var out: [UInt8] = []
        for p in parts { out.append(contentsOf: Array(p.utf8)) }
        return out
    }
}
