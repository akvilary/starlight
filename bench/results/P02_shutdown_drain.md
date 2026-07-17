# P02 — Shutdown drain + idempotent closeConnection

A/B test, 12 threads × 256 conns × 10s, endpoint `/`, 30s cooldown,
interleaved baseline/fix/baseline/fix.

|              | run 1    | run 2    | run 3    | AVG     |
|--------------|----------|----------|----------|---------|
| baseline     | 251,641  | 287,506  | 290,470  | 276,539 |
| fix          | 289,751  | 286,251  | 251,940  | 275,981 |
| delta        |          |          |          | -0.2%   |

**Verdict**: no regression. Symmetric noise pattern (baseline warms up,
fix tires out — typical thermal/cache behaviour, not the change).

Hot path untouched: drainJobs() is only called once per shutdown (after
recoverOrphanedContinuations), closeConnection's `if let` adds one
branch prediction hit on the cold path.

Tests: 92/92 passed (2 new ShutdownTests added).
  - start() returns within 2s of shutdown()
  - shutdown() is idempotent
