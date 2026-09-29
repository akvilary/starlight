# http-codec v0.3.x hardening — end-to-end plaintext check

Change under test: http-codec v0.3.0–v0.3.1 (+ http v0.3.x inline header
storage) — production-hardening audit of the codec: smuggling suite,
pure borrowed parser with the runtime-view fast path (request heads
parse without copying), 16-byte SWAR scanners, inline HeaderName/
HeaderValue storage (≤15 B, zero heap per typical header), immortal
static token constants, per-read body stall deadlines, trailers,
101-tunnel handoff. starlight Worker adapted (error taxonomy mapping,
keep-alive fold, streamIdentity, RequestTrailers).

Build: `swift build -c release --product hello-world` (router mode, `/`
returns "Hello, World!").

## AGENTS.md protocol — wrk -t12 -c100 -d3s, `/` (3 runs)

| run | req/s    |
|-----|----------|
| 1   | 307,535  |
| 2   | 303,607  |
| 3   | 297,099  |
| AVG | **302,747** |

Last recorded baseline (MIO restructuring A/B, same protocol):
285,166–285,838 → **+6.2%**, no regression.

## Detailed — wrk -t12 -c256 -d10s --latency, `/`

|            | req/s   | p50    | p99     | socket errors |
|------------|---------|--------|---------|---------------|
| BASELINE   | 296,771 | 622µs  | 9.91ms  | —             |
| this run   | 332,156 | 507µs  | 5.16ms  | 0             |

**+11.9%** vs baseline, p50 −19%, p99 −48%.
