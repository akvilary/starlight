# P09 — Remove RequestContext.responseBuffer + Router.handle

A/B test, 12 threads × 256 conns × 10s, endpoint `/`, 25s cooldown,
interleaved baseline/fix. (Cumulative since P22 — P09 builds on top
of P22 + P12.)

|              | run 1    | run 2    | run 3    | AVG     |
|--------------|----------|----------|----------|---------|
| baseline     | 289,266  | 281,138  | 282,156  | 284,187 |
| fix          | 309,656  | 321,883  | 327,728  | 319,756 |
| delta        |          |          |          | +12.5%  |

**Verdict**: no regression. P09 alone adds ~+0.4% (within noise) on
top of P22 + P12. The real win is code clarity: one fewer field on
every RequestContext, one fewer place where 404 logic lives.

## What landed

Two pieces of dead code removed:

### 1. `RequestContext.responseBuffer` (512 B per connection)

This buffer was declared on RequestContext with the intent of letting
handlers reuse it for zero-alloc responses. But handlers receive the
context as `borrowing RequestContext` and cannot pass it as `inout` —
the field was never usable from a handler. Its only actual use was in
`Router.handle()` for the 404 response body — a single call site.

The codec already has its own `responseBuffer` (also 512 B) that it
uses for 400/413/500 responses. With Router.handle gone (see below),
the codec's buffer covers 404 as well — one buffer instead of two,
-512 B per connection.

### 2. `Router.handle(_ ctx: inout RequestContext) async throws`

This was a thin wrapper around `Router.match()` + handler invocation,
plus a 404 response synthesis. It was the only user of
`RequestContext.responseBuffer`.

The codec on the hot path never called it — it called `Router.match()`
directly and synthesised its own 404 into its own reusable buffer
(zero-alloc). So Router.handle was a parallel path that could drift
out of sync with the codec's dispatch logic.

Removed entirely. The codec is the single source of truth for
dispatch + 404/500 synthesis.

### Migration

RouterTests previously used `router.handle()` to drive dispatch tests.
Added a test-only `dispatch()` helper at the top of RouterTests.swift
that mirrors what the codec does (match → set params → invoke
handler). Tests stay readable without pulling in the codec as a test
dependency.

Removed the `routerHandleRethrows` test from HandlerThrowsTests —
the codec's 500-synthesis on throw is already covered by
`asyncHandlerThrows` and `tryParseThrowingSyncHandler`.

Doc comments updated: HTTPHandler's `throws` semantics now describe
the codec as the catcher, not Router.handle.

Tests: 119/119 passed (was 120 — removed 1 obsolete test).
