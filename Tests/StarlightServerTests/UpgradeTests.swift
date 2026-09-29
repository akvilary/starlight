//===----------------------------------------------------------------------===//
//
//  UpgradeTests.swift
//  StarlightServerTests
//
//  End-to-end protocol-upgrade tunnel: a real PollEventLoop over a
//  socketpair, driven through `UpgradedConnection`'s raw I/O — the
//  same machinery the Worker hands a 101 UpgradeHandoff handler.
//
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
import Testing
import Foundation
import Pulsar
@testable import StarlightServer

@Suite("Upgrade tunnel")
struct UpgradeTests {

    func makeSocketpair() -> (client: CInt, server: CInt)? {
        var fds: [CInt] = [0, 0]
        guard socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &fds) == 0 else {
            return nil
        }
        return (fds[0], fds[1])
    }

    /// Blocking read of exactly `n` bytes from a blocking fd.
    func readExact(_ fd: CInt, _ n: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: n)
        var got = 0
        while got < n {
            let r = out.withUnsafeMutableBufferPointer { ptr in
                Glibc.read(fd, ptr.baseAddress! + got, n - got)
            }
            if r <= 0 { return Array(out[0..<got]) }
            got += r
        }
        return out
    }

    @Test("UpgradedConnection echoes initialBytes + live round-trip")
    func tunnelEcho() async throws {
        let loop = try PollEventLoop()
        guard let sp = makeSocketpair() else {
            Issue.record("socketpair failed")
            return
        }
        let (clientFd, serverFd) = sp
        // Register BEFORE running the loop (channel table is
        // loop-thread state).
        let channelId = try loop.registerChannel(fd: serverFd)
        let loopThread = Thread { try? loop.run() }
        loopThread.start()
        try await Task.sleep(for: .milliseconds(30))
        defer {
            // From the test thread only fd-close + shutdown are legal
            // (cancelChannel is loop-thread-only; shutdown tears the
            // loop's channels down itself — same cleanup shape as the
            // pulsar loop tests).
            _ = Glibc.close(clientFd)
            _ = Glibc.close(serverFd)
            loop.shutdown()
        }

        let upgraded = UpgradedConnection(
            eventLoop: loop,
            fd: serverFd,
            channelId: channelId,
            initialBytes: Array("EARLY".utf8)
        )

        // The tunnel session — on the loop's executor, per the
        // pulsar threading contract (the Worker runs the handoff
        // handler on the connection's loop Task the same way).
        let session = Task(executorPreference: loop) { [upgraded] in
            // 1. Deliver the pre-handshake bytes.
            guard await upgraded.write(upgraded.initialBytes) else { return }
            // 2. One live echo round-trip.
            if let chunk = await upgraded.read() {
                _ = await upgraded.write(chunk)
            }
        }

        // Client side: receives the pre-handshake bytes first…
        let early = readExact(clientFd, 5)
        #expect(early == Array("EARLY".utf8))
        // …then a full round-trip through the tunnel.
        _ = Array("HELLO".utf8).withUnsafeBufferPointer {
            Glibc.write(clientFd, $0.baseAddress!, 5)
        }
        let echoed = readExact(clientFd, 5)
        #expect(echoed == Array("HELLO".utf8))

        // The handler returning is the tunnel's only shutdown path
        // (the driver's teardown owns the channel afterwards).
        await session.value
    }
}
#endif
