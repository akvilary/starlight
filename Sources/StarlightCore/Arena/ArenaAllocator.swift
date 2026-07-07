//===----------------------------------------------------------------------===//
//
//  ArenaAllocator.swift
//  StarlightCore
//
//  Per-request bump allocator, modelled on H2O's `h2o_mem_pool_t`.
//
//  Design:
//  - A linked list of byte chunks with a bump pointer into the current chunk.
//  - Allocation is O(1): advance the bump pointer by `bytes`, rounded up
//    to `alignment`. No per-allocation bookkeeping, no fragmentation
//    handling.
//  - Chunk sizes grow exponentially (start at `initialChunkSize`, double
//    each time a new chunk is needed) so we amortize the per-chunk syscall
//    cost across many allocations.
//  - `reset()` is the bulk-free primitive: it walks every chunk and resets
//    its `usedBytes` to zero, but does NOT release the memory back to the
//    system allocator. The next request on the same arena reuses the same
//    chunks without a single `malloc` call — this is the single biggest
//    allocation-related win over Hummingbird/Vapor.
//  - `deinit` releases every chunk back to the system allocator in one pass.
//
//  Lifetime: an arena is owned by a `RequestContext`, which is in turn
//  owned by a connection's handler Task. The arena is `~Copyable` so the
//  Swift compiler enforces exactly-one-owner semantics: a moved-out arena
//  cannot be referenced again, and the receiver is responsible for
//  calling `deinit`.
//
//===----------------------------------------------------------------------===//

/// A single chunk of arena memory.
///
/// `final class` rather than `~Copyable struct` because the owning
/// `ArenaAllocator` needs to store an array of chunks, and Swift's
/// `Array` requires `Copyable` elements. Using a class also gives us
/// the `deinit`-driven memory release path for free: when a chunk is
/// dropped from the array, its `deinit` runs and releases the buffer.
///
/// ARC overhead is negligible here — chunks are created rarely (only
/// when the arena grows) and there are usually 1-3 of them per request.
/// The per-request hot path goes through `bumpAllocate`, which does no
/// ARC traffic on the chunk at all.
@usableFromInline
final class ArenaChunk: @unchecked Sendable {
    /// The backing memory.
    @usableFromInline let buffer: UnsafeMutableRawBufferPointer

    /// Bump pointer: number of bytes from `buffer.baseAddress` that are
    /// currently in use. Reset to 0 by `ArenaAllocator.reset()`.
    @usableFromInline var usedBytes: Int

    /// Capacity of `buffer`. Cached here so callers don't have to chase the
    /// pointer to discover the chunk size.
    @usableFromInline var capacity: Int { buffer.count }

    @inlinable
    init(buffer: UnsafeMutableRawBufferPointer) {
        self.buffer = buffer
        self.usedBytes = 0
    }

    @inlinable
    deinit {
        buffer.deallocate()
    }
}

/// Per-request bump allocator.
///
/// - Invariant: `chunks.last` is the chunk that new allocations come from.
///   Earlier chunks are kept (their `usedBytes` are preserved across
///   allocations and reset to 0 only by `reset()`), so that `reset()` can
///   reuse them for the next request without any `malloc` calls.
///
/// - Invariant: `nextChunkSize` grows exponentially, starting at
///   `initialChunkSize` and doubling each time a new chunk is allocated,
///   capped at `maxChunkSize`. The cap prevents one pathological request
///   from causing the arena to hold onto gigabytes forever.
@frozen
public struct ArenaAllocator: ~Copyable, Sendable {
    /// Owning array of chunks. The last element is the "current" chunk
    /// (the one that bump allocations come from).
    @usableFromInline var chunks: [ArenaChunk]

    /// Size of the next chunk that will be allocated. Doubles on each new
    /// chunk allocation up to `maxChunkSize`.
    @usableFromInline var nextChunkSize: Int

    /// Initial chunk size — the size the first chunk will be allocated at,
    /// and the size `nextChunkSize` resets to in `reset()`.
    @usableFromInline let initialChunkSize: Int

    /// Upper bound on a single chunk's size. Once reached, new chunks
    /// keep getting allocated at this size.
    @usableFromInline let maxChunkSize: Int

    /// Construct an empty arena. No memory is allocated until the first
    /// `allocate(...)` call.
    ///
    /// - Parameters:
    ///   - initialChunkSize: size of the first chunk allocated. Default
    ///     4 KiB — comfortably fits most HTTP request headers + URL +
    ///     query string on a single page.
    ///   - maxChunkSize: upper bound on a single chunk. Default 4 MiB.
    public init(
        initialChunkSize: Int = 4 * 1024,
        maxChunkSize: Int = 4 * 1024 * 1024
    ) {
        precondition(initialChunkSize > 0, "initialChunkSize must be positive")
        precondition(maxChunkSize >= initialChunkSize, "maxChunkSize must be >= initialChunkSize")
        self.chunks = []
        self.nextChunkSize = initialChunkSize
        self.initialChunkSize = initialChunkSize
        self.maxChunkSize = maxChunkSize
    }

    /// Allocate `bytes` of memory aligned to `alignment`.
    ///
    /// - Important: The returned memory is **uninitialized**. Reading
    ///   it before writing is undefined behaviour.
    /// - Important: The returned pointer is valid only until the next
    ///   `reset()` or `releaseAll()` call on this arena, or until the
    ///   arena is deinitialized. Do not escape the pointer past those
    ///   points — it will dangle or alias a different allocation.
    ///
    /// - Returns: a pointer to `bytes` of uninitialized memory.
    ///
    /// - Complexity: O(1) when the request fits in the current chunk;
    ///   O(chunks) only when a new chunk must be allocated (rare under
    ///   exponential growth).
    public mutating func allocate(
        bytes: Int,
        alignment: Int = MemoryLayout<Int>.alignment
    ) -> UnsafeMutableRawBufferPointer {
        precondition(bytes >= 0, "bytes must be non-negative")
        precondition(alignment > 0 && (alignment & (alignment - 1)) == 0,
                     "alignment must be a positive power of two")
        if bytes == 0 {
            // Match `UnsafeMutableRawBufferPointer.allocate(byteCount: 0)`
            // semantics: return a zero-length buffer with a nil base.
            return UnsafeMutableRawBufferPointer(start: nil, count: 0)
        }

        // Fast path: bump within the current chunk.
        if let result = self.bumpAllocate(bytes: bytes, alignment: alignment) {
            return result
        }

        // Slow path: current chunk is full (or there isn't one). Allocate
        // a new chunk large enough to satisfy this request and any
        // follow-on allocations.
        let chunkSize = max(bytes, self.nextChunkSize)
        let buffer = UnsafeMutableRawBufferPointer.allocate(
            byteCount: chunkSize,
            alignment: max(alignment, MemoryLayout<Int>.alignment)
        )
        var chunk = ArenaChunk(buffer: buffer)
        // Place the allocation at offset 0 in the fresh chunk. We rely
        // on `UnsafeMutableRawBufferPointer.allocate` returning
        // `alignment`-aligned memory, so the base address satisfies any
        // smaller or equal alignment requirement.
        chunk.usedBytes = bytes
        self.chunks.append(chunk)

        // Grow the next chunk size exponentially for amortized O(1)
        // amortized allocation cost.
        self.nextChunkSize = min(self.nextChunkSize * 2, self.maxChunkSize)

        return UnsafeMutableRawBufferPointer(
            start: buffer.baseAddress,
            count: bytes
        )
    }

    /// Allocate room for `count` instances of `T`, returning a typed pointer.
    /// The memory is **uninitialized**; the caller is responsible for
    /// `initialize`-ing every byte before reading it back.
    ///
    /// - Important: The returned pointer is valid only until the next
    ///   `reset()` or `releaseAll()` call on this arena, or until the
    ///   arena is deinitialized. Do not escape the pointer past those
    ///   points — it will dangle.
    /// - Important: The memory is **uninitialized**. Reading it
    ///   before calling `initialize(to:)` / `initializeMemory(as:repeating:)`
    ///   is undefined behaviour.
    public mutating func allocateUninitialized<T>(
        _ type: T.Type,
        count: Int
    ) -> UnsafeMutableBufferPointer<T> {
        let byteCount = count * MemoryLayout<T>.stride
        let alignment = MemoryLayout<T>.alignment
        let raw = self.allocate(bytes: byteCount, alignment: alignment)
        // SAFETY: `byteCount` is a multiple of `MemoryLayout<T>.stride`,
        // `alignment` matches, and the raw buffer's base is non-nil for
        // non-zero byte counts (we handled `bytes == 0` above).
        let typedBase = raw.baseAddress!.assumingMemoryBound(to: T.self)
        return UnsafeMutableBufferPointer(start: typedBase, count: count)
    }

    /// Allocate room for a single `T` and initialize it to `value`. Returns
    /// a pointer that is valid until the next `reset()` or `releaseAll()`
    /// on this arena, or until the arena is deinitialized — whichever
    /// happens first.
    ///
    /// - Important: Escaping the returned pointer past the next
    ///   `reset()` is undefined behaviour. The arena's bump pointer
    ///   will advance past the underlying storage on the next
    ///   allocation, but the storage may be reused by another
    ///   allocation after `reset()` — at which point the old pointer
    ///   aliases different data.
    public mutating func allocate<T>(_ value: T) -> UnsafeMutablePointer<T> {
        let ptr = self.allocateUninitialized(T.self, count: 1).baseAddress!
        ptr.initialize(to: value)
        return ptr
    }

    /// Bulk-free: reset the bump pointer in every chunk to 0. Memory is
    /// NOT released back to the system allocator — the chunks stay owned
    /// by this arena for reuse by the next request.
    ///
    /// Use this between requests on a keep-alive connection so the same
    /// arena can serve hundreds of requests without a single `malloc`.
    ///
    /// - Complexity: O(chunks). Independent of the number of allocations.
    public mutating func reset() {
        for i in self.chunks.indices {
            self.chunks[i].usedBytes = 0
        }
        // Reset the chunk-size growth so a fresh request on a long-lived
        // arena doesn't keep allocating at the previous request's grown
        // size. The exponential growth will happen again if the new
        // request genuinely needs the space.
        self.nextChunkSize = self.initialChunkSize
    }

    /// Release every chunk back to the system allocator. The arena is
    /// left in an empty state, as if just constructed. Useful for
    /// long-running arenas that want to shed memory between bursts.
    public mutating func releaseAll() {
        // Each chunk is a `final class`; dropping it from the array runs
        // its `deinit`, which releases the underlying buffer.
        self.chunks.removeAll()
        self.nextChunkSize = self.initialChunkSize
    }

    @inlinable
    deinit {
        // Array's own deinit drops every element. Each `ArenaChunk` is a
        // `final class`, so dropping it runs the chunk's `deinit`, which
        // releases its `UnsafeMutableRawBufferPointer`. Nothing else to do.
    }

    // MARK: - Internals

    /// Try to satisfy an allocation from the current (last) chunk.
    /// Returns `nil` if the chunk doesn't have enough room.
    @usableFromInline
    @inline(__always)
    mutating func bumpAllocate(
        bytes: Int,
        alignment: Int
    ) -> UnsafeMutableRawBufferPointer? {
        guard let lastIndex = self.chunks.indices.last else {
            return nil
        }
        // `withUnsafeMutableBufferPointer` on a class-backed array would be
        // ideal, but `chunks` is a struct array. We index directly —
        // safe because we hold unique ownership (the arena is `~Copyable`
        // and `mutating`).
        let chunk = self.chunks[lastIndex]
        let base = chunk.buffer.baseAddress!
        let baseAddrInt = Int(bitPattern: base)
        let alignedAddrInt = (baseAddrInt + chunk.usedBytes + alignment - 1)
            & ~(alignment - 1)
        let offsetInChunk = alignedAddrInt - baseAddrInt
        guard offsetInChunk + bytes <= chunk.capacity else {
            return nil
        }
        self.chunks[lastIndex].usedBytes = offsetInChunk + bytes
        return UnsafeMutableRawBufferPointer(
            start: UnsafeMutableRawPointer(bitPattern: alignedAddrInt),
            count: bytes
        )
    }

    // MARK: - Stats

    /// Total bytes reserved by all chunks. Useful for `initialChunkSize`
    /// tuning and for sanity-checking memory pressure.
    @inlinable
    public var reservedBytes: Int {
        self.chunks.reduce(into: 0) { acc, chunk in
            acc &+= chunk.capacity
        }
    }

    /// Bytes currently in use across all chunks (sum of `usedBytes`,
    /// including padding). Useful for stats.
    @inlinable
    public var usedBytes: Int {
        self.chunks.reduce(into: 0) { acc, chunk in
            acc &+= chunk.usedBytes
        }
    }

    /// Number of chunks currently held.
    @inlinable
    public var chunkCount: Int { self.chunks.count }
}
