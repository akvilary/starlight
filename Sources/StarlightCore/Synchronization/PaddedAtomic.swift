//===----------------------------------------------------------------------===//
//
//  PaddedAtomic.swift
//  StarlightCore
//
//  Atomic counters padded to a cache line to prevent false sharing between
//  cores. This is the H2O pattern (`char _unused_avoir_false_sharing[32];`
//  in `h2o_context_state_t`) — when multiple threads update adjacent atomic
//  counters from their own event loops, the cache-line ping-pong dominates
//  throughput. Padding each counter to its own line (64 bytes on x86_64 /
//  arm64) gives every core exclusive ownership of its line.
//
//===----------------------------------------------------------------------===//

import Synchronization

/// 128-byte padding — two cache lines on x86_64 / arm64, which is what the
/// prefetcher / spatial prefetch logic actually needs to fully isolate
/// adjacent atomics from one another (Intel's spatial prefetcher pulls pairs
/// of 64-byte lines; a single 64-byte pad is not sufficient in the worst case).
@frozen
public struct CacheLinePadding {
    private let _p0: UInt64 = 0
    private let _p1: UInt64 = 0
    private let _p2: UInt64 = 0
    private let _p3: UInt64 = 0
    private let _p4: UInt64 = 0
    private let _p5: UInt64 = 0
    private let _p6: UInt64 = 0
    private let _p7: UInt64 = 0
    private let _p8: UInt64 = 0
    private let _p9: UInt64 = 0
    private let _p10: UInt64 = 0
    private let _p11: UInt64 = 0
    private let _p12: UInt64 = 0
    private let _p13: UInt64 = 0
    private let _p14: UInt64 = 0
    private let _p15: UInt64 = 0

    @inlinable public init() {}
}

/// An `Atomic<Int64>` flanked by two cache-line paddings — occupies three
/// full cache lines, with the atomic in the middle line, so neither the
/// preceding nor following field in the owning struct can pull this line into
/// a remote core's cache.
///
/// Use this for any cross-loop counter (active connections, request count,
/// bytes transferred). Per-loop counters that are only touched from one
/// thread do not need padding.
@frozen
public struct PaddedAtomicInt64: ~Copyable, Sendable {
    /// Cache-line padding before the atomic. Internal rather than
    /// public so external code cannot observe or modify the padding
    /// bytes (which exist solely to control the struct's memory
    /// layout — touching them would defeat the false-sharing
    /// isolation).
    internal var _leading = CacheLinePadding()
    /// `Atomic<T>` is `~Copyable` and `@_staticExclusiveOnly`: it must be a
    /// `let`. Its mutator operations are `nonmutating`, so this still allows
    /// incrementing via an immutable binding.
    public let _value = Atomic<Int64>(0)
    /// See `_leading`.
    internal var _trailing = CacheLinePadding()

    @inlinable public init() {}

    /// Relaxed load — fine for stats; we don't need ordering against
    /// non-atomic memory.
    @inlinable
    public func load() -> Int64 {
        return self._value.load(ordering: .relaxed)
    }

    /// Relaxed add — returns the *previous* value.
    @inlinable
    public func add(_ delta: Int64) -> Int64 {
        return self._value.wrappingAdd(delta, ordering: .relaxed).oldValue
    }

    /// Relaxed increment — convenience for `add(1)`.
    @inlinable
    public func increment() -> Int64 {
        return self.add(1)
    }
}
