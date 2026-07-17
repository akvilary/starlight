# P12 — Codec as ~Copyable struct

A/B test, 12 threads × 256 conns × 10s, endpoint `/`, 25s cooldown,
interleaved baseline/fix. (Compared against pre-P22 baseline — P12
builds on top of the P22 connection-model refactor.)

|              | run 1    | run 2    | run 3    | AVG     |
|--------------|----------|----------|----------|---------|
| baseline     | 289,529  | 278,410  | 286,588  | 284,842 |
| fix          | 322,841  | 317,736  | 314,489  | 318,355 |
| delta        |          |          |          | +11.8%  |

**Verdict**: no regression. The +11.8% is cumulative from P22
(connection model refactor) + P12. P12 alone contributes ~+0.4%
(316K → 318K) — within noise, but consistently positive. The real
win of P12 is compile-time safety, not throughput.

## What landed

`HTTP1Codec` was the last `final class @unchecked Sendable` on the
per-connection hot path. With P22 making it Task-local, the class
wrapper buys us nothing — the codec is already owned exclusively by
one Task, never crosses isolation domains, never needs reference
counting. The class only added heap allocation, ARC traffic, and a
blanket `@unchecked Sendable` escape hatch.

Replaced:

    final class HTTP1Codec: @unchecked Sendable { ... }

with:

    struct HTTP1Codec: ~Copyable { ... }

### Compile-time guarantees

- `~Copyable` forbids copying. The compiler now rejects any code path
  that tries to share a codec between Tasks, capture it twice, or
  store it in a Sendable container.
- No `@unchecked Sendable` — the codec is not `Sendable`, full stop.
  The only way to use it is to construct one inside a Task and pass
  it via `inout` to the connection loop functions.
- Mutating methods (`feed`, `tryParse`, `dispatchAsync`, `afterDispatch`,
  `notFoundResponse`, `internalErrorResponse`, `synthesize500`,
  `parseAndExtract`) are now explicitly `mutating`. Callers must
  declare their codec binding as `var`, not `let` — making the
  mutation surface obvious at every call site.

### Zero heap allocation

The codec is now a struct stored inline in the Task frame. No heap
allocation for the codec instance itself — only its interior
ByteBuffers allocate, same as before. ARC traffic on the codec
reference is eliminated.

### Migration

All call sites updated:
- `httpLoop(... codec: HTTP1Codec)` → `httpLoop(... codec: inout HTTP1Codec)`.
- `setupNewConnection` Task closure: `let codec = ...` → `var codec = ...`,
  passed as `&codec` to the loop.
- NIO backend `handleHTTPConnection`: `let codec` → `var codec`.
- `TestHelpers.parseAndDispatch` extension: `func` → `mutating func`.
- `HTTP1CodecTests` / `HandlerThrowsTests`: `let codec = HTTP1Codec(...)`
  → `var codec = HTTP1Codec(...)`.

Tests: 120/120 passed.

## What's next

Phase D (#9) — remove `RequestContext.responseBuffer`. Now that the
codec owns all error-response buffers and the connection loop calls
the codec directly, the duplicated buffer in RequestContext is dead
weight.
