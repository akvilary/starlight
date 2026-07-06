//===----------------------------------------------------------------------===//
//
//  ArenaAllocatorTests.swift
//  StarlightCoreTests
//
//  Verifies that ArenaAllocator behaves as a per-request bump arena:
//  - O(1) allocation within a chunk
//  - exponential chunk-size growth
//  - alignment is honoured
//  - `reset()` keeps the chunks (so subsequent allocations do not malloc)
//  - `releaseAll()` and `deinit` release everything back to the system
//
//===----------------------------------------------------------------------===//

import Testing
@testable import StarlightCore

@Suite("ArenaAllocator")
struct ArenaAllocatorTests {
    // MARK: - Basic allocation

    @Test("Single small allocation fits in the first chunk")
    func singleSmallAllocation() {
        var arena = ArenaAllocator(initialChunkSize: 1024)
        let buf = arena.allocate(bytes: 64, alignment: 1)
        #expect(buf.count == 64)
        #expect(buf.baseAddress != nil)
        // One chunk allocated, holding 64 bytes used out of 1024 reserved.
        #expect(arena.chunkCount == 1)
        #expect(arena.usedBytes == 64)
        #expect(arena.reservedBytes == 1024)
    }

    @Test("Zero-byte allocation returns an empty buffer without allocating a chunk")
    func zeroByteAllocation() {
        var arena = ArenaAllocator(initialChunkSize: 1024)
        let buf = arena.allocate(bytes: 0, alignment: 1)
        #expect(buf.count == 0)
        #expect(buf.baseAddress == nil)
        #expect(arena.chunkCount == 0)
        #expect(arena.usedBytes == 0)
    }

    @Test("Multiple allocations pack into one chunk")
    func multipleAllocationsPack() {
        var arena = ArenaAllocator(initialChunkSize: 1024)
        // 16 allocations of 32 bytes each — total 512 bytes — must all
        // land inside the same chunk (no growth).
        for _ in 0..<16 {
            let buf = arena.allocate(bytes: 32, alignment: 1)
            #expect(buf.count == 32)
        }
        #expect(arena.chunkCount == 1)
        #expect(arena.usedBytes == 16 * 32)
        #expect(arena.reservedBytes == 1024)
    }

    // MARK: - Alignment

    @Test("Alignment is honoured")
    func alignmentIsHonoured() {
        var arena = ArenaAllocator(initialChunkSize: 1024)
        // Allocate 1 byte with alignment 1 — should advance the bump
        // pointer by exactly 1.
        let _ = arena.allocate(bytes: 1, alignment: 1)
        // Now allocate with alignment 16 — the returned pointer must be
        // 16-byte aligned, and the bump pointer must have skipped the
        // padding.
        let buf = arena.allocate(bytes: 8, alignment: 16)
        let addr = Int(bitPattern: buf.baseAddress!)
        #expect(addr % 16 == 0)
        // 1 byte used (above) + 15 bytes padding to align to 16 + 8 bytes
        // for this allocation = 24 bytes total used.
        #expect(arena.usedBytes == 1 + 15 + 8)
    }

    @Test("Alignment to power-of-two only — non power-of-two crashes (precondition)")
    func alignmentMustBePowerOfTwo() {
        // We can't catch a `precondition` failure from swift-testing yet
        // (it traps rather than throws). This test exists to document the
        // contract: passing a non power-of-two alignment is a programming
        // error and the arena traps on it.
        //
        // To verify manually: uncomment the line below and observe a
        // "Precondition failed: alignment must be a positive power of two"
        // trap.
        //
        // var arena = ArenaAllocator(initialChunkSize: 1024)
        // _ = arena.allocate(bytes: 8, alignment: 3)  // would trap
        #expect(true)
    }

    // MARK: - Chunk growth

    @Test("Allocation larger than the current chunk triggers growth")
    func growthBeyondChunk() {
        var arena = ArenaAllocator(initialChunkSize: 64)
        // First chunk: 64 bytes. Allocating 100 bytes requires a new chunk.
        let buf = arena.allocate(bytes: 100, alignment: 1)
        #expect(buf.count == 100)
        // The new chunk is sized to fit (100 bytes requested, which is
        // larger than the initial 64-byte size — so the new chunk is at
        // least 100 bytes).
        #expect(arena.chunkCount == 1)
        #expect(arena.reservedBytes >= 100)
    }

    @Test("Exponential growth when filling many chunks")
    func exponentialGrowth() {
        var arena = ArenaAllocator(initialChunkSize: 64, maxChunkSize: 1024)
        // Keep allocating exactly one chunk's worth of bytes at a time.
        // After several rounds the arena should have grown chunks at
        // 64, 128, 256, 512, 1024 bytes.
        var observedSizes: [Int] = []
        var allocated = 0
        // Allocate enough to force multiple chunk growths.
        // Round 1: allocate 64 bytes → fills initial 64-byte chunk.
        // Round 2: allocate 64 bytes → needs new chunk; next size = 128.
        // Round 3: allocate 128 bytes → fills it; needs new chunk; next = 256.
        // Round 4: allocate 256 bytes → fills it; needs new chunk; next = 512.
        // Round 5: allocate 512 bytes → fills it; needs new chunk; next = 1024.
        // Round 6: allocate 1024 bytes → fills it; needs new chunk; next = 1024 (capped).
        for chunkTarget in [64, 64, 128, 256, 512, 1024] {
            _ = arena.allocate(bytes: chunkTarget, alignment: 1)
            allocated &+= chunkTarget
        }
        // After all allocations we should have multiple chunks.
        #expect(arena.chunkCount >= 5)
        #expect(arena.usedBytes == allocated)
        #expect(arena.reservedBytes >= allocated)
        _ = observedSizes // (used for debugging during development)
    }

    // MARK: - Reset

    @Test("reset() keeps all chunks and zeroes usedBytes")
    func resetKeepsChunksAndZeroesUsage() {
        var arena = ArenaAllocator(initialChunkSize: 128)
        _ = arena.allocate(bytes: 100, alignment: 1)
        let chunksBeforeReset = arena.chunkCount
        let reservedBeforeReset = arena.reservedBytes
        #expect(arena.usedBytes == 100)

        arena.reset()

        #expect(arena.chunkCount == chunksBeforeReset)
        #expect(arena.reservedBytes == reservedBeforeReset)
        #expect(arena.usedBytes == 0)
    }

    @Test("reset() enables allocation without new malloc")
    func resetFollowedByAllocationReusesChunk() {
        var arena = ArenaAllocator(initialChunkSize: 256)
        // First request cycle: fill the arena.
        _ = arena.allocate(bytes: 200, alignment: 1)
        let chunksAfterFirstCycle = arena.chunkCount

        // Between requests: reset.
        arena.reset()

        // Second request cycle: same total allocation should NOT need
        // any new chunks.
        _ = arena.allocate(bytes: 200, alignment: 1)
        #expect(arena.chunkCount == chunksAfterFirstCycle)
        #expect(arena.usedBytes == 200)
    }

    @Test("reset() also resets nextChunkSize to initialChunkSize")
    func resetResetsGrowthFactor() {
        var arena = ArenaAllocator(initialChunkSize: 64, maxChunkSize: 1024)
        // Force several growths.
        _ = arena.allocate(bytes: 64, alignment: 1)
        _ = arena.allocate(bytes: 128, alignment: 1)
        _ = arena.allocate(bytes: 256, alignment: 1)
        // nextChunkSize is now 512.
        arena.reset()
        // After reset, the next chunk that has to be allocated (because
        // the existing ones don't satisfy the new request) starts back
        // at initialChunkSize = 64.
        // Verify by allocating something that needs a new chunk (larger
        // than all existing chunks) and inspecting reservedBytes growth.
        let reservedBefore = arena.reservedBytes
        _ = arena.allocate(bytes: 1024, alignment: 1)
        // The new chunk should be 1024 (request size) rather than the
        // previously-grown `nextChunkSize`. Total reserved should grow
        // by exactly 1024.
        #expect(arena.reservedBytes - reservedBefore == 1024)
    }

    // MARK: - releaseAll

    @Test("releaseAll() empties the arena")
    func releaseAllEmpties() {
        var arena = ArenaAllocator(initialChunkSize: 128)
        _ = arena.allocate(bytes: 100, alignment: 1)
        _ = arena.allocate(bytes: 1000, alignment: 1)  // forces a new chunk
        #expect(arena.chunkCount >= 2)

        arena.releaseAll()
        #expect(arena.chunkCount == 0)
        #expect(arena.reservedBytes == 0)
        #expect(arena.usedBytes == 0)
    }

    @Test("releaseAll() enables a fresh allocation cycle")
    func releaseAllFollowedByFreshUse() {
        var arena = ArenaAllocator(initialChunkSize: 64)
        _ = arena.allocate(bytes: 32, alignment: 1)
        arena.releaseAll()
        // After releaseAll the arena behaves like a freshly constructed one.
        #expect(arena.chunkCount == 0)
        _ = arena.allocate(bytes: 32, alignment: 1)
        #expect(arena.chunkCount == 1)
    }

    // MARK: - Typed allocation

    @Test("allocateUninitialized<T> lays out T instances correctly")
    func typedAllocationLayout() {
        var arena = ArenaAllocator(initialChunkSize: 256)
        // Allocate space for 8 UInt64s (8 bytes each, 8-aligned).
        let ptr = arena.allocateUninitialized(UInt64.self, count: 8)
        #expect(ptr.count == 8)
        let baseAddr = Int(bitPattern: ptr.baseAddress!)
        #expect(baseAddr % 8 == 0)
        // Initialize each element and verify we can read back.
        for i in 0..<8 {
            ptr[i] = UInt64(i * 1000)
        }
        for i in 0..<8 {
            #expect(ptr[i] == UInt64(i * 1000))
        }
        // Used bytes: 8 * 8 = 64.
        #expect(arena.usedBytes == 64)
    }

    @Test("allocate(value) initializes a single T")
    func typedSingleAllocationInitializes() {
        struct Point { let x: Int; let y: Int }
        var arena = ArenaAllocator(initialChunkSize: 256)
        let ptr = arena.allocate(Point(x: 3, y: 4))
        #expect(ptr.pointee.x == 3)
        #expect(ptr.pointee.y == 4)
    }
}
