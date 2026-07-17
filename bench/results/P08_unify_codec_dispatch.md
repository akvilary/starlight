# P08 — Unify codec dispatch path (single tryParse + dispatchAsync)

A/B test, 12 threads × 256 conns × 10s, endpoint `/`, 25s cooldown,
interleaved baseline/fix.

|              | run 1    | run 2    | run 3    | AVG     |
|--------------|----------|----------|----------|---------|
| baseline     | 230,025  | 280,846  | 282,575  | 264,482 |
| fix          | 282,391  | 248,513  | 281,739  | 270,881 |
| delta        |          |          |          | +2.4%   |

**Verdict**: no regression. The +2.4% is a warming artifact (baseline
run 1 was cold at 230K, fix run 2 dipped after a hot run 1). Average
is within noise. The dispatch logic is now unified — backends cannot
drift apart in how they synthesise 4xx/5xx responses.

## What landed

The codec previously had two parallel dispatch paths:

  1. `tryParse()` — async, always `await`ed even for sync handlers.
     Used by the NIO backend (Server.handleHTTPConnection).
  2. `tryParseSync()` + `dispatchAsync()` — sync fast path. Used by
     the epoll and io_uring backends (EpollExecutorLoop,
     IORingExecutorLoop).

The two paths already differed in their 404 handling (only the sync
path went through `Router.handle`'s own 404 logic; the async path
inlined its own) and in their handling of "no router, no handler"
(both synthesised 500 but with separate code). Tests only covered
the async path, so the sync path that production Linux requests
actually exercised was untested.

Replaced with a single entry point:

  tryParse() -> ParseResult
    case .response(HTTPResponse)  // sync handler completed
    case .needsAsync              // caller must await dispatchAsync()
    case .incomplete              // need more bytes

All three backends now drive the codec with the same shape:

    parseLoop: while true {
        switch codec.tryParse() {
        case .incomplete:           break parseLoop
        case .response(let r):      write(r); if !r.keepAlive { return }
        case .needsAsync:           let r = await codec.dispatchAsync()
                                    write(r); if !r.keepAlive { return }
        }
    }

`dispatchAsync()` simplified: it now only consumes the cached
`pendingMatch` set by `tryParse()` on `.needsAsync`. Previously it
also re-dispatched via `router.handle` / `handler` as a fallback —
dead code after the unification (precondition guards against misuse).

Helper extraction in the codec:
  - `notFoundResponse()` — single source of the 404 body.
  - `internalErrorResponse()` — single source of the 500 body.
  - `synthesize500(_:)` — delegates to `internalErrorResponse()`,
    kept as a separate name for clarity at the throw site.

NIO backend also gets a small `writeResponse(_:into:stats:)` helper
to avoid duplication between sync and async dispatch arms.

## Migration

In-repo callers updated:
- Server.swift `handleHTTPConnection` — switched from `while let r =
  await tryParse()` to the switch-based loop.
- EpollExecutorLoop / IORingExecutorLoop — `tryParseSync()` →
  `tryParse()`.
- HTTP1CodecTests / HandlerThrowsTests — adapted via a test-only
  `parseAndDispatch()` helper in TestHelpers.swift that mirrors the
  pre-A-8 signature (`async -> HTTPResponse?`). Tests stay readable
  without spelling out the switch on every line.

Tests: 119/119 passed (no new tests — existing coverage now exercises
the same path that production Linux traffic takes).
