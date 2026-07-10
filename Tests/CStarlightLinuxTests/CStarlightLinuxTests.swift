//===----------------------------------------------------------------------===//
//
//  CStarlightLinuxTests.swift
//
//  Unit tests for the io_uring C shim — verifies ring lifecycle,
//  SQE submission / CQE completion roundtrip, and socket setup.
//
//===----------------------------------------------------------------------===//

#if os(Linux)

import Testing
import CStarlightLinux

@Suite("CStarlightLinux / io_uring ring")
struct CStarlightLinuxTests {

    // MARK: - Ring lifecycle

    @Test("Ring init + exit with 64 entries succeeds")
    func ringInitExit() {
        var ring = sl_ring()
        let ret = sl_ring_init(&ring, 64)
        #expect(ret == 0, "sl_ring_init returned \(ret)")
        #expect(ring.ring_fd >= 0)
        #expect(ring.sqes != nil)
        #expect(ring.cqes != nil)
        #expect(ring.sq_kmask != nil)
        sl_ring_exit(&ring)
        #expect(ring.ring_fd == -1)
    }

    @Test("Ring init rejects zero entries")
    func ringInitZeroFails() {
        var ring = sl_ring()
        let ret = sl_ring_init(&ring, 0)
        #expect(ret < 0)
        sl_ring_exit(&ring)
    }

    @Test("Ring init with 1024 entries")
    func ringInitLarge() {
        var ring = sl_ring()
        let ret = sl_ring_init(&ring, 1024)
        #expect(ret == 0)
        sl_ring_exit(&ring)
    }

    // MARK: - SQE / CQE roundtrip

    @Test("NOP SQE completes successfully")
    func nopRoundtrip() {
        var ring = sl_ring()
        #expect(sl_ring_init(&ring, 32) == 0)
        defer { sl_ring_exit(&ring) }

        // Submit a NOP operation
        guard let sqe = sl_get_sqe(&ring) else {
            Issue.record("sl_get_sqe returned NULL — ring should not be full")
            return
        }
        sqe.pointee.opcode = numericCast(IORING_OP_NOP.rawValue)
        sl_sqe_set_data(sqe, 0x4242)

        let submitted = sl_submit(&ring)
        #expect(submitted == 1, "sl_submit returned \(submitted)")

        // Wait for completion
        var cqe: UnsafeMutablePointer<io_uring_cqe>? = nil
        let waitRet = sl_wait_cqe(&ring, &cqe)
        #expect(waitRet == 0, "sl_wait_cqe returned \(waitRet)")
        #expect(cqe != nil)

        if let c = cqe {
            #expect(c.pointee.res == 0, "NOP result should be 0, got \(c.pointee.res)")
            #expect(sl_cqe_data(c) == 0x4242, "user_data mismatch")
            sl_cqe_seen(&ring)
        }
    }

    @Test("Multiple NOPs complete and return correct user_data")
    func multipleNops() {
        var ring = sl_ring()
        #expect(sl_ring_init(&ring, 64) == 0)
        defer { sl_ring_exit(&ring) }

        // Submit 5 NOPs with distinct user_data tags
        for i in 1...5 {
            guard let sqe = sl_get_sqe(&ring) else {
                Issue.record("sl_get_sqe returned NULL at iteration \(i)")
                return
            }
            sqe.pointee.opcode = numericCast(IORING_OP_NOP.rawValue)
            sl_sqe_set_data(sqe, UInt64(i * 100))
        }

        let submitted = sl_submit(&ring)
        #expect(submitted == 5, "sl_submit returned \(submitted)")

        // Collect completions
        var seen: [UInt64] = []
        for _ in 0..<5 {
            var cqe: UnsafeMutablePointer<io_uring_cqe>? = nil
            let ret = sl_wait_cqe(&ring, &cqe)
            #expect(ret == 0)
            if let c = cqe {
                seen.append(sl_cqe_data(c))
                sl_cqe_seen(&ring)
            }
        }

        #expect(seen.count == 5)
        // Completions may arrive in any order, but user_data must match
        let sorted = seen.sorted()
        #expect(sorted == [100, 200, 300, 400, 500])
    }

    @Test("sl_get_sqe returns NULL when ring is full")
    func sqeRingFull() {
        var ring = sl_ring()
        #expect(sl_ring_init(&ring, 4) == 0)
        defer { sl_ring_exit(&ring) }

        // Fill all 4 slots (don't submit yet)
        for i in 0..<4 {
            let sqe = sl_get_sqe(&ring)
            #expect(sqe != nil, "Expected non-nil SQE at \(i)")
            sqe!.pointee.opcode = numericCast(IORING_OP_NOP.rawValue)
            sl_sqe_set_data(sqe!, UInt64(i))
        }

        // 5th should be NULL — ring is full
        let overflow = sl_get_sqe(&ring)
        #expect(overflow == nil, "Expected NULL when ring is full")
    }

    // MARK: - Socket helper

    @Test("sl_listen creates a valid listener")
    func listenSucceeds() {
        let fd = sl_listen("127.0.0.1", 18080, 128)
        #expect(fd >= 0, "sl_listen returned \(fd)")
        if fd >= 0 {
            close(fd)
        }
    }

    @Test("sl_set_tcp_nodelay works on a socket pair")
    func tcpNodelay() {
        let fd = sl_listen("127.0.0.1", 18081, 128)
        #expect(fd >= 0)
        defer { close(fd) }

        let ret = sl_set_tcp_nodelay(fd)
        // setsockopt on a listening socket should succeed
        #expect(ret == 0, "sl_set_tcp_nodelay returned \(ret)")
    }
}

#endif // os(Linux)
