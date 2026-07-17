# P05 — QueryView: URL query string parsing + UTF-8 + URL-decode

A/B test, 12 threads × 256 conns × 10s, endpoint `/`, 25s cooldown,
interleaved baseline/fix.

|              | run 1    | run 2    | run 3    | AVG     |
|--------------|----------|----------|----------|---------|
| baseline     | 252,442  | 246,546  | 266,876  | 255,288 |
| fix          | 269,137  | 284,306  | 271,187  | 274,877 |
| delta        |          |          |          | +7.7%   |

**Verdict**: no regression. Fix consistently faster (typical warming
pattern — cache state, not the change). Hot-path overhead is one
`SearchAlgorithm.findByte(0x3F)` scan per request line; the parser
copies query bytes into `ctx.query` only when a `?` is present.

## What landed

- **New file `Sources/StarlightHTTP/QueryView.swift`**: lazy view over
  the URL query string, SWAR-accelerated (`findSeparator`,
  `findEquals`, `keyMatches` helpers — no linear byte loops).
- **`HTTP1Parser`**: tracks `queryStart` / `queryLength`, SWAR-finds
  `?` (replaces the previous linear scan, fixing #17 in passing), and
  copies the query slice into `ctx.query` directly from `feed()` —
  same encapsulation as `ctx.headers.copyBlock` (no public-internal
  API leak).
- **`RequestContext`**: new `query: QueryView` field, cleared in
  `reset()` before `path.clear()` to avoid COW on shared storage
  (fixes #13 in passing).
- **`HTTP1Codec`**: no change — the parser owns query capture, the
  codec only reads `parser.queryLength` as a sanity check.

## API

```swift
ctx.query["foo"]                       // first URL-decoded value
ctx.query.values(for: "id")            // [String] for multi-valued
ctx.query.forEachValue(of: "tag") { }  // zero-alloc iteration
ctx.query.isEmpty / .count
```

- Case-sensitive keys (RFC 3986 — matches Express/Flask/Echo).
- `+` → space, `%XX` → byte (invalid hex keeps literal `%`).
- Raw UTF-8 and %-encoded UTF-8 both work — `String(decoding:as:UTF8.self)`
  interprets the decoded bytes, so Cyrillic / CJK / emoji values
  materialise correctly.
- `?foo` (no `=`) → empty value; `?=value` (empty key) → ignored.

Tests: 113/113 passed (92 + 21 new QueryView tests covering absence,
single/multi pairs, empty keys, separators, case sensitivity, URL
decoding, percent-encoded UTF-8, raw UTF-8, emoji).

## Note for future maintainers

Adding fields to `RequestContext` (a `~Copyable` struct whose
`@inlinable init()` is inlined into every dependent module) requires
a clean build (`rm -rf .build && swift build`). Incremental builds
reuse stale inlined init code with the old layout, causing a SIGSEGV
in unrelated tests. This is an SPM/Swift 6.2 limitation, not a bug in
the change.
