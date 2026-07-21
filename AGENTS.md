# AGENTS.md — Starlight

## Workflow rules

### Before every commit

1. **Build release**: `swift build -c release`
2. **Run benchmark 3 times**: `wrk -t12 -c100 -d3s http://localhost:8080/`
3. **Compare to last known baseline** (recorded in ROADMAP.md)
4. **Regression threshold**: > 5% drop = investigate before committing
5. **Record the number** in the commit message

Current baseline: **~260K req/s** (release, loopback, 12-core AMD 5600H)

### Build commands

```bash
# Debug build (faster compile, slower runtime)
swift build

# Release build (for benchmarks)
swift build -c release

# Run tests
swift test

# Run hello-world server
swift run hello-world
# or: .build/release/hello-world 8080
```

### Package layout

```
../http       = http crate (Request, Response, Method, StatusCode, Body)
../hyper      = hyper crate (H1 codec: Decoder, Encoder, Conn, Dispatcher)
../mio        = mio crate (epoll primitives: Poll, Registry, Token, Events)
starlight     = axum crate (Router, Handler, Extractors, Middleware, Server)
```

### Architecture decisions (locked)

- Worker is an `actor` (not `@unchecked Sendable`)
- `PollEventLoop.drainJobs()` must be `while` loop (Swift Task = 2 jobs)
- `PollEventLoop.checkIsolated()` uses `pthread_self` comparison
- Task-per-connection (not per-accept, not per-request)
- Body is an enum: `.empty` / `.buffered([UInt8])` / `.stream(AsyncSequence)`
