# P11 — Handler can throw → 500 on uncaught error

A/B test, 12 threads × 256 conns × 10s, endpoint `/`, 25s cooldown,
interleaved baseline/fix.

|              | run 1    | run 2    | run 3    | AVG     |
|--------------|----------|----------|----------|---------|
| baseline     | 292,396  | 284,658  | 288,268  | 288,441 |
| fix          | 288,347  | 283,301  | 284,618  | 285,422 |
| delta        |          |          |          | -1.0%   |

**Verdict**: small, stable regression. The cost of adding `throws`
semantics to the dispatch path: the compiler emits error-propagation
code around `try fn(ctx)` / `try await fn(ctx)` even when the handler
never throws. Same trade-off paid by Vapor, Hummingbird, and every
Swift HTTP framework that exposes a throwing handler API.

The regression is acceptable in exchange for the correctness benefit:
previously, a thrown error would crash the process; now it produces a
clean 500 with the connection closed cleanly.

## What landed

- `HTTPHandler` / `AsyncHTTPHandler` now `throws` / `async throws`.
- `Router.handle(_:)` now `async throws` — propagates handler errors.
- `Middleware` wrap closures auto-promoted to throwing — no `rethrows`
  needed (Swift infers throw from the underlying HTTPHandler type).
- `HTTP1Codec` catches throws at every dispatch site (tryParseSync,
  tryParse, dispatchAsync) and synthesises a `500 Internal Server
  Error` response with `keepAlive: false`. Connection closes after
  the response is written (a thrown error may indicate corrupted state).
- No logging at the codec layer — `stderr` is global mutable state
  under Swift 6 strict concurrency. A future error-handling middleware
  can take over logging without runtime-tier hazards.

## Future improvements (not in this PR)

- Catch-middleware: `Middleware { error, ctx in ... }` that wraps the
  handler in `do/catch` and converts errors to custom responses.
- Specific error types: `throw HTTPError.notFound` syntactic sugar
  on top of `any Error`.

Tests: 119/119 passed (113 + 6 new HandlerThrows tests covering
sync/async throw paths, tryParseSync, and non-throwing regression).
