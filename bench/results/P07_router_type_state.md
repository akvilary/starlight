# P07 — Router: type-state pattern (RouterBuilder + Router)

A/B test, 12 threads × 256 conns × 10s, endpoint `/`, 25s cooldown,
interleaved baseline/fix.

|              | run 1    | run 2    | run 3    | AVG     |
|--------------|----------|----------|----------|---------|
| baseline     | 280,789  | 281,338  | 283,028  | 281,718 |
| fix          | 296,115  | 280,571  | 266,721  | 281,136 |
| delta        |          |          |          | -0.2%   |

**Verdict**: no regression. Hot-path logic (`match()` / `handle()` /
`matchBytes()`) is byte-for-byte identical to before — only the type
boundary moved.

## What landed

The previous `Router` was a `final class ... @unchecked Sendable` with
mutable route/middleware arrays guarded only by an `Atomic<Bool> isFrozen`
flag and a `precondition` in `add()`. The "no concurrent writes during
build" invariant was a runtime convention, not a compile-time guarantee.

Replaced with the type-state pattern:

  ┌─────────────────────────────┐         ┌─────────────────────┐
  │  RouterBuilder              │  build  │  Router             │
  │  (class, mutable, !Sendable)│ ──────► │  (struct, immutable │
  │                             │         │   Sendable)         │
  │  get/post/put/...           │         │                     │
  │  use(middleware)            │         │  match(...)         │
  │  add(...)                   │         │  handle(...)        │
  └─────────────────────────────┘         └─────────────────────┘

### Compile-time guarantees

- `RouterBuilder` is NOT `Sendable` — Swift refuses to share it across
  actor boundaries, so route registration is confined to one thread by
  construction.
- `Router` is `Sendable` (no `@unchecked`): every stored property is a
  `let`-bound array of `Sendable` value types. Safe to share between
  12 event loops.
- `Atomic<Bool> isFrozen`, the `precondition` in `add()`/`use()`, and
  the runtime `freeze()` call from `Server.start()` — all deleted. The
  type system enforces the invariant now.

### API

```swift
// Explicit form:
let builder = RouterBuilder()
builder.get("/health") { _ in .plaintext("ok") }
builder.use(authMiddleware)
let router = builder.build()             // immutable, Sendable
try await server.start(router: router)

// Convenience (closure-based):
let router = Router {
    $0.get("/health") { _ in .plaintext("ok") }
    $0.use(authMiddleware)
}
```

### Migration

All callsites in the repo updated to the new API:
- `Router()` → `RouterBuilder()` for build phase.
- `router.match(...)` / `router.handle(...)` → `builder.build().match(...)`.
- `Server.start(router:)` now takes the immutable `Router` directly.
- Removed `router?.freeze()` from `StarlightServer.start()` — `Router`
  arrives already composed.
- `HTTP1Codec(router:)` stores the immutable `Router`.

Tests: 113/113 passed.
