# Starlight — Roadmap

Direct port of Rust's [axum](https://github.com/tokio-rs/axum) to Swift.
The single source of truth is the axum source tree + hyper source tree.
Deviations happen only when Swift's type system or runtime model
doesn't allow a literal port.

## Текущее состояние

| Компонент | Статус |
|---|---|
| `../http` package (port of `http` crate) | ✅ 5 tests |
| `../hyper` package (port of `hyper::proto::h1`) | ✅ 18 tests |
| `Starlight` (axum umbrella) | ✅ 39 tests |
| HTTP/1.1 end-to-end pipeline | ✅ работает |
| Graceful shutdown (auto SIGINT/SIGTERM) | ✅ |
| Streaming bodies + chunked TE | ✅ |
| Router (nest, merge, layer, route_layer, withState) | ✅ |
| HandlerService0-6 (arity up to 6 extractors) | ✅ |
| Extractors (14 типов) | ✅ |
| IntoResponseParts + tuple responses | ✅ |
| Middleware (Trace, Timeout, Cors, RateLimit) | ✅ |
| SWAR byte search | ✅ |
| Zero-copy ReadBuffer (port of BytesMut) | ✅ |
| writev(2) multi-buffer output | ✅ |
| Reusable HeaderMap + Extensions | ✅ |
| Extension<T> + Redirect + MatchedPath + OriginalUri | ✅ |
| Handler closure ergonomics | ✅ |
| Tier 1 bug fixes (B1-B5) | ✅ |
| Tier 2 API parity (with_state, Handler4-6, IntoResponseParts) | ✅ |
| Tier 3 axum parity (Sse, DefaultBodyLimit, Host) | ✅ |
| Бенчмарк | ~234K req/s (release, 12-core, wrk -t12 -c100 -d3s) |
| CompressionLayer | ❌ |
| Sse<Stream> structured helper | ❌ |
| WebSocket | ❌ |
| TLS | ❌ |
| HTTP/2 | ❌ |
| Static file serving | ❌ |

## Архитектурный фундамент (зафиксирован)

- **8 модулей** mirror axum workspace 1:1
- **`Worker` actor** (без `@unchecked Sendable`) с `unownedExecutor` → `PollEventLoop`
- **Task-per-connection** (не per-accept, не per-request)
- **`PollEventLoop.drainJobs()`** — `while` loop (Swift Task = 2 jobs)
- **`PollEventLoop.checkIsolated()`** — `pthread_self == loopThreadId`
- **`ReadBuffer`** — Swift аналог `bytes::BytesMut` (zero-copy read)
- **Reusable HeaderMap + Extensions** — 0 alloc/req после warmup
- **writev(2)** — header + body в один syscall
- **SO_REUSEPORT** — N listener fds, kernel-balanced

---

## Done — Phase 1: Production HTTP/1.1

- [x] **1.1** Graceful shutdown
- [x] **1.2** Streaming bodies + chunked TE
- [x] **1.3** Router nest + merge + layer + route_layer
- [x] **1.4** Extractors: Bytes, Form, ConnectInfo, Request

## Done — Phase 2: Performance

- [x] **2.1** SWAR byte search (`hyper/ByteSearch.swift`)
- [x] **2.2** Zero-copy ReadBuffer (`hyper/ReadBuffer.swift`)
- [x] **2.3** writev(2) multi-buffer output
- [x] **2.4** Reusable HeaderMap + Extensions + @inlinable (+2.2%)

## Done — Phase 3: Middleware

- [x] **3.2** TraceLayer (configurable hooks, stderr opt-in)
- [x] **3.3** CorsLayer (preflight, origin restriction, spec-compliant)
- [x] **3.4** TimeoutLayer + RateLimitLayer

## Done — Extra axum parity

- [x] Extension<T> (extractor + layer + response)
- [x] Redirect (to/permanent/temporary/seeOther)
- [x] MatchedPath + OriginalUri extractors
- [x] Handler closure ergonomics (get/post/put/delete/patch)
- [x] BoxService: Service conformance
- [x] Tier 1 bug fixes (B1-B5: ConnectInfo, Json status, Router init, CORS, default shutdown)

## Done — Tier 2: axum API parity

- [x] **2.1** `Router.withState(_:)` — late-bind state
- [x] **2.2** HandlerService4, 5, 6 — arity up to 6 extractors
- [x] **2.3** IntoResponseParts + `Response(.created, from: Json(x))`
- [~] **2.4** ~~Option<T> extractors~~ — SKIPPED (не Swift-idiomatic)

---

## Done — Tier 3: Remaining axum parity

- [x] **3.1** Sse<Stream> + SseEvent (structured SSE response)
- [x] **3.2** DefaultBodyLimit (layer + extension-based limit)
- [x] **3.3** Host extractor (Forwarded / X-Forwarded-Host / Host)

---

## Phase 4 — HTTP protocol features

### 4.1 CompressionLayer (~6ч)

**Референс:** `tower_http::compression`.

- [ ] Gzip encoder via zlib
- [ ] Auto-select по Accept-Encoding
- [ ] Skip для < 256 bytes

### 4.2 WebSocket (~6ч)

**Референс:** `axum::extract::ws` + `tungstenite`.

- [ ] RFC 6455 framing
- [ ] `ws://` upgrade
- [ ] `WebSocket` extractor

### 4.3 TLS (~6ч)

- [ ] NIOSSL / BoringSSL integration
- [ ] `TLSConfig` struct
- [ ] HTTPS endpoint

### 4.4 Static file serving (~4ч)

- [ ] `sendfile(2)` zero-copy
- [ ] ETag / Range / MIME

---

## Phase 5 — Advanced performance

### 5.1 Radix trie router (~8ч)

**Референс:** [`matchit`](https://github.com/ibraheemdev/matchit).

- [ ] Port matchit path trie
- [ ] O(path-length) matching (vs current O(routes × path))

### 5.2 SIMD HTTP parser (~6ч)

- [ ] SIMD16<UInt8> byte search
- [ ] Profile-driven optimization

---

## Phase 6 — Ecosystem & v0.1.0

- [ ] README + quickstart + benchmarks
- [ ] Examples (hello-world, rest-api, middleware, sse)
- [ ] TestClient utility
- [ ] DocC documentation
- [ ] CI (GitHub Actions)
- [ ] Tag `v0.1.0`

---

## Known deviations from axum (justified)

| Deviation | Reason |
|---|---|
| `throws ExtractionRejection` instead of `Result<Self, Rejection>` | Swift `Result.Failure: Error` conflicts with `IntoResponse` |
| SO_REUSEPORT multi-listener (not single) | Swift has no work-stealing runtime |
| `withState` replaces state value (not type parameter) | Swift methods can't change generic parameter |
| HandlerService0-6 (not variadic generics 0-16) | Swift has no variadic async closures |
| `ReadBuffer` class (ARC) instead of `BytesMut` value type | Swift `~Copyable` + `Sendable` conflict |
| `Body` enum (not `BoxBody` trait object) | Swift has no trait objects |
| `Option<T>` extractors skipped | Not Swift-idiomatic; Swift uses `if let` |
| `Response(.created, from: Json(x))` instead of tuple `(StatusCode, T)` | Swift tuples can't conform to protocols |

## Principles

1. **axum 1:1** — каждая абстракция имеет соответствие в axum source
2. **Hot path — zero-allocation** после первого keep-alive запроса
3. **Swift idioms** где Rust literal не переносится
4. **Tower-compatible** — Service/Layer работает без HTTP-specific shortcuts
5. **Тесты обязательны**
6. **Benchmarks после каждого коммита** — regression если > 5% drop

## Session log

| # | Дата | Что сделано |
|---|---|---|
| 1 | 2026-07-21 | Skeleton: 8 axum modules, protocols, 15 tests |
| 2 | 2026-07-21 | Reference axum source directly (no look-back at old impl) |
| 3 | 2026-07-21 | Extracted `../http` + `../hyper` as standalone packages |
| 4 | 2026-07-21 | Working HTTP server: Worker actor, Task-per-conn, 136K req/s |
| 5 | 2026-07-21 | Graceful shutdown (SIGINT/SIGTERM, drain timeout) |
| 6 | 2026-07-21 | Streaming bodies + chunked TE (request + response) |
| 7 | 2026-07-21 | Router nest + merge + layer + route_layer |
| 8 | 2026-07-21 | Extractors: Bytes, Form, ConnectInfo, Request |
| 9 | 2026-07-21 | SWAR byte search in hyper |
| 10 | 2026-07-21 | TraceLayer + TimeoutLayer + CorsLayer + RateLimitLayer |
| 11 | 2026-07-21 | Extension<T> + Redirect (axum::Extension, axum::response::Redirect) |
| 12 | 2026-07-21 | Handler closure ergonomics (axum-style get/post/...) |
| 13 | 2026-07-21 | MatchedPath + OriginalUri extractors |
| 14 | 2026-07-21 | Zero-copy ReadBuffer (port of bytes::BytesMut) |
| 15 | 2026-07-21 | writev(2) multi-buffer output |
| 16 | 2026-07-21 | Reusable HeaderMap + Extensions + @inlinable (+2.2%) |
| 17 | 2026-07-21 | Full audit: 5 bugs, 24 missing, 12 deviations identified |
| 18 | 2026-07-21 | Tier 1 fixes: B1-B5 (ConnectInfo, Json status, Router init, CORS, shutdown) |
| 19 | 2026-07-21 | Tier 2: with_state + HandlerService4-6 + IntoResponseParts |
| 20 | 2026-07-21 | Tier 3: Sse<Stream> + DefaultBodyLimit + Host extractor |
| 21 | — | _Next: Phase 4 (Compression / WebSocket / TLS / Static files)_ |
