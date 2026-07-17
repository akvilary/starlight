# P24 — Eliminate unsafe public API

A/B test, 12 threads × 256 conns × 10s, endpoint `/`, 25s cooldown,
interleaved baseline/fix. (Cumulative across all audit phases.)

|              | run 1    | run 2    | run 3    | AVG     |
|--------------|----------|----------|----------|---------|
| baseline     | 277,460  | 294,766  | 248,426  | 273,551 |
| fix          | 326,245  | 313,487  | 324,908  | 321,547 |
| delta        |          |          |          | +17.5%  |

**Verdict**: no regression. P24 itself is a zero-line safety fix
(removing dead code); the +17.5% is cumulative from P1 through P23.

## What landed

### Removed `HeaderView.bytes(for:)` — last unsafe public API

`HeaderView.bytes(for name: String) -> UnsafeBufferPointer<UInt8>?`
was the **only** public API in the entire framework that returned an
unsafe pointer. It was the Swift equivalent of returning `*const u8`
from a public function in Rust — unacceptable for a production-grade
framework.

The method had **zero callers** in the entire codebase (verified via
grep across Sources/ and Tests/). It was dead code that leaked an
unsafe abstraction into the public surface.

Removed entirely. No replacement needed — the existing subscript
`headers["name"] -> String?` and `headers.value("name", equals: "...")`
cover all real use cases. Both are safe (no unsafe pointers in their
signatures). This matches what Hummingbird and Vapor expose.

### Removed `@unchecked Sendable` from `ServerStats`

`ServerStats` had `@unchecked Sendable` but all its stored properties
are `let`-bound `PaddedAtomicInt64` (which is `Sendable`). The
compiler derives `Sendable` automatically — the `@unchecked` was
unnecessary. Replaced with plain `Sendable`.

### Final safety audit

    Unsafe types in PUBLIC API:  0
    @unchecked Sendable (total): 7

The remaining 7 `@unchecked Sendable` classes are all justified:

| Class | Why @unchecked is OK |
|-------|---------------------|
| `PollEventLoop` | Custom executor — mutable state accessed only from loop thread (analogous to `DispatchQueue`) |
| `IORingEventLoop` | Same — io_uring ring is SINGLE_ISSUER |
| `IORingBox` | Internal wrapper around `~Copyable IORing` (can't be stored without a class) |
| `EpollExecutorLoop` | Internal — mutable state synchronised via loop thread |
| `IORingExecutorLoop` | Same |
| `StarlightServer` | Public — mutations only in `start()`/`shutdown()`, synchronised via task isolation |

These are low-level infrastructure types (custom executors, server
lifecycle). Their `@unchecked` is the same pattern Apple uses for
`DispatchQueue`, `OperationQueue`, etc.

## What this completes

With P24, the framework's public API surface is **fully safe**:
- No `UnsafePointer`, `UnsafeBufferPointer`, or raw pointer returns.
- No `@unchecked Sendable` on data types (only on executor infra).
- All public collection-like types (`HeaderView`, `QueryView`, `Params`)
  return `String`, `Bool`, or `[String]` — no escape hatches.

Tests: 119/119 passed.
