//===----------------------------------------------------------------------===//
//
//  ArenaAllocator.swift
//  StarlightCore
//
//  Per-request bump allocator (Phase 1 placeholder).
//
//  Modeled on H2O's `h2o_mem_pool_t`: a linked list of fixed-size chunks with
//  a bump pointer, plus a thread-local recycler that keeps warm chunks on the
//  core that freed them. Allocations are O(1) and have no per-allocation
//  bookkeeping; the entire arena is freed in one operation at request end.
//
//  Phase 0 ships this stub so the module compiles and the API surface is
//  visible. The full bump allocator lands in Phase 1, built on
//  `ManagedBuffer<Header, UInt8>` for tail-allocated chunks.
//
//===----------------------------------------------------------------------===//

import Synchronization

/// Placeholder arena allocator. Allocates from the default Swift heap today;
/// will be replaced in Phase 1 with a chunked bump allocator that mirrors
/// `h2o_mem_pool_t`.
///
/// The API is shaped the way the final allocator will be used by
/// `RequestContext`, so call sites do not change once the implementation
/// lands.
public struct ArenaAllocator: ~Copyable, Sendable {
    @usableFromInline var _totalAllocated: Int = 0

    public init() {}

    /// Allocate `byteCount` bytes with `alignment`. The returned memory is
    /// valid until `reset()` or `deinit` is called on the allocator.
    ///
    /// Phase 0 implementation: delegates to `UnsafeMutableRawBufferPointer.allocate`.
    /// Phase 1 implementation: bump-allocates from the current chunk, falling
    /// over to a new chunk (with exponential backoff) when full.
    public mutating func allocate(byteCount: Int, alignment: Int) -> UnsafeMutableRawBufferPointer {
        self._totalAllocated &+= byteCount
        return UnsafeMutableRawBufferPointer.allocate(byteCount: byteCount, alignment: alignment)
    }

    /// Allocate a single instance of `T` initialized to `value`. Convenience
    /// over `allocate(byteCount:alignment:)`.
    public mutating func allocate<T>(_ value: T) -> UnsafeMutablePointer<T> {
        let p = UnsafeMutablePointer<T>.allocate(capacity: 1)
        p.initialize(to: value)
        self._totalAllocated &+= MemoryLayout<T>.size
        return p
    }

    /// Free every allocation made since the previous `reset()` in one bulk
    /// operation. O(chunks), independent of the number of allocations.
    ///
    /// Phase 0: no-op (allocations are owned by the caller); the field is
    /// still reset so the allocator's reported footprint is accurate.
    public mutating func reset() {
        self._totalAllocated = 0
    }

    /// Bytes currently outstanding since the last `reset()`. Useful for stats
    /// and for sizing the next chunk.
    public var totalAllocated: Int { self._totalAllocated }
}
