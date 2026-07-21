# P0.3 — Fix fd leak in `drainConnections`

A/B test, 12 threads × 256 conns × 10s, endpoint `/`, 15s cooldown,
3 runs each. No active connections at shutdown — the fix changes the
connection-fd-cleanup path, not the steady-state hot path.

|              | run 1    | run 2    | run 3    | AVG      | delta vs baseline |
|--------------|----------|----------|----------|----------|-------------------|
| baseline     | 273,449  | 274,191  | 274,473  | 274,038  | —                 |
| fix          | 278,239  | 274,958  | 267,363  | 273,520  | −0.19%            |

**Verdict**: no regression. Delta within run-to-run noise (~3%).

## What landed

### Connection fd leak on shutdown (epoll + io_uring)

`EpollExecutorLoop.drainConnections` and `IORingExecutorLoop.drainConnections`
cancelled channels but never closed the corresponding connection fds. The
in-code comment claimed "fd is closed by the connection Task on its exit",
but Tasks that were not parked on `eventLoop.read`/`write` at shutdown time
never reached their cleanup code — their fds leaked forever.

Concretely, the leak surfaces in three scenarios:

1. **Task parked on a child Task** (e.g. `await codec.dispatchAsync()` whose
   handler does `Task.sleep` or any non-trivial async work). The child never
   completes, the parent never resumes, `closeConnection` never runs.

2. **Task continuation enqueued mid-`drainJobs`**. The final `drainJobs` in
   `eventLoop.run()` snapshots `loopJobs` at entry; continuations enqueued
   *during* that drain (e.g. a resumed parent parking on its next I/O op)
   are never themselves drained — the loop's `run()` returns and they hang.

3. **Task spawned just before shutdown**. The Task's body starts during
   the final `drainJobs`, allocates its read buffer, enters `httpLoop`,
   parks on `eventLoop.read`. The read is armed against a now-stopped
   loop and never completes.

In all three cases the connection fd stays open in `connections` after
`eventLoop.run()` returns. The previous `drainConnections` left it there.

### Fix

Close every fd in `drainConnections` unconditionally. Safe against
double-close: `closeConnection(fd:)` removes the entry from `connections`
before closing, so any fd still present in `drainConnections` is closed
exactly once. A Task that later (somehow) calls `closeConnection` on the
same fd finds the entry missing and is a no-op.

### Regression tests

Three new tests in `EpollShutdownFdLeakTests`:

- `epollDrainConnectionsClosesFds` — white-box: injects socketpair fds
  into `EpollExecutorLoop.connections` and verifies `fstat` returns -1
  after `drainConnections`.
- `ioRingDrainConnectionsClosesFds` — symmetric, for `IORingExecutorLoop`.
- `repeatedEpollShutdownDoesNotAccumulateFds` — end-to-end: counts
  `/proc/self/fd` entries across 3 start/shutdown cycles (+1 warmup).

Verified the white-box tests catch the regression by temporarily
reverting the fix — both failed with the expected `fstat returned 0`.

To enable injection, `connections` and `drainConnections` were promoted
from `private` to `internal`. The containing classes themselves are
already `internal` — `@testable import StarlightServer` is the standard
way to access impl details from tests.

Tests: 130/130 passed (was 127, +3 new).
