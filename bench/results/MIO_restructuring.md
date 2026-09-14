# MIO restructuring — A/B performance check

Change under test: `mio` restructured (Poll class → struct, Registry =
ARC-owner of the epoll fd, Waker deinit simplification, StaticString
PollError, auto-`EPOLLRDHUP` on `.readable`, mio-parity Ready predicates).
`starlight`/`pulsar` sources unchanged — the MIO API stayed source-compatible.

A/B via sandboxed trees: `bench-old` = mio@9932aa3, `bench-new` = mio worktree.
Runs interleaved (old/new alternating) to cancel the thermal drift observed
over the session (~10% downward, hits both sides equally).

## AGENTS.md protocol — wrk -t12 -c100 -d3s, `/`

|            | run 1   | run 2   | run 3   | AVG     |
|------------|---------|---------|---------|---------|
| old mio    | 289,684 | 284,440 | 283,391 | 285,838 |
| new mio    | 295,438 | 282,620 | 277,439 | 285,166 |
| delta      |         |         |         | **−0.2%** |

## Detailed — wrk -t12 -c256 -d10s --latency, `/` (5 pairs)

|            | 1       | 2       | 3       | 4       | 5       | AVG     |
|------------|---------|---------|---------|---------|---------|---------|
| old mio    | 293,652 | 295,650 | 284,060 | 265,894 | 270,782 | 282,008 |
| new mio    | 284,815 | 291,964 | 279,850 | 262,551 | 271,439 | 278,124 |
| delta      | −3.0%   | −1.2%   | −1.5%   | −1.3%   | +0.2%   | **−1.4%** |

`/health` (1 pair): 269,477 → 266,307 (−1.2%).

Latency percentiles overlap completely (p50 626–717 µs, p99 4.6–7.5 ms on
both sides); wrk reported 0 socket/non-2xx errors.

**Verdict: no regression** — worst paired delta −3.0%, aggregate −0.2%…−1.4%,
all well inside the 5% threshold. Both variants sit above the ROADMAP
baseline (~260K req/s).

Notes:
- The small consistent ~1% on `/` c256 is dominated by run-to-run noise and
  code-layout effects; the only real hot-path additions are one extra bit
  test in `Event.isReadable` (`IN || PRI`, mio parity) and the
  `EPOLLRDHUP` OR in register/reregister — both far below measurement noise
  at ~1M events/s.
- Behavioural side effect: pulsar's `processChannelEvent` `isReadClosed`
  branch (EPOLLRDHUP → read-EOF) was dead code on old mio (the bit was
  never requested); it is live now — half-close is delivered as read-EOF
  instead of falling through to the read→0 path. No measurable cost.
- mio tests: 27/27 (debug + release).
