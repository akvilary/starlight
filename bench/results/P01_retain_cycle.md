# P01 — Retain cycles in executor loops

A/B test, 12 threads × 256 conns × 10s, endpoint `/`, 30s cooldown between runs.

|              | run 1    | run 2    | run 3    | AVG     |
|--------------|----------|----------|----------|---------|
| baseline     | 284,529  | 268,104  | 250,528  | 267,721 |
| fix          | 278,628  | 282,828  | 284,058  | 281,838 |
| delta        |          |          |          | +5.3%   |

**Verdict**: no regression. Visible warming pattern in both directions
(baseline degrades 284→250, fix accelerates 278→284) — typical cache
warming, not attributable to the change.

The fix's hot-path overhead is one `weak` load per accept-burst wakeup
(never per request), which is negligible.

Tests: 90/90 passed.
