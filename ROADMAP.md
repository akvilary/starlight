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
| HTTP/1.1 end-to-end | ✅ работает |
| Graceful shutdown (auto SIGINT/SIGTERM) | ✅ |
| Streaming bodies + chunked TE | ✅ |
| Router (nest, merge, layer, route_layer) | ✅ |
| Extractors (14 типов) | ✅ |
| Middleware (Trace, Timeout, Cors, RateLimit) | ✅ |
| SWAR byte search | ✅ |
| Zero-copy ReadBuffer (port of BytesMut) | ✅ |
| writev(2) multi-buffer output | ✅ |
| Reusable HeaderMap + Extensions | ✅ |
| Extension<T> + Redirect + MatchedPath + OriginalUri | ✅ |
| Handler closure ergonomics | ✅ |
| Tier 1 bug fixes (B1-B5) | ✅ |
| Бенчмарк | ~231K req/s (release, 12-core, wrk -t12 -c100 -d3s) |
| CompressionLayer | ❌ |
| with_state() type-state pattern | ❌ |
| HandlerService4+ (arity > 3) | ❌ |
| IntoResponseParts + tuple responses | ❌ |
| Option<T> / Result<T,E> extractors | ❌ |
| Sse<Stream> structured helper | ❌ |
| WebSocket | ❌ |
| TLS | ❌ |
| HTTP/2 | ❌ |

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

- [x] **1.1** Graceful shutdown (`280c554`)
- [x] **1.2** Streaming bodies + chunked TE (`8d917f3`)
- [x] **1.3** Router nest + merge + layer + route_layer (`03cd521`)
- [x] **1.4** Extractors: Bytes, Form, ConnectInfo, Request

## Done — Phase 2: Performance

- [x] **2.1** SWAR byte search (`hyper/ByteSearch.swift`)
- [x] **2.2** Zero-copy ReadBuffer (`hyper/ReadBuffer.swift`)
- [x] **2.3** writev(2) multi-buffer output
- [x] **2.4** Reusable HeaderMap + Extensions + @inlinable

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
- [x] Tier 1 bug fixes (B1-B5)

---

## Next — Tier 2: axum API parity

**Цель:** Покрыть оставшиеся важные API из audit'а.

### 2.1 `with_state(_:)` — type-state pattern

**Референс:** `axum::routing::Router::with_state`.

- [ ] `Router<S>.withState(_ state: S) -> Router<NoState>`
- [ ] Handlers accessible after state provision
- [ ] Тест: build router without state → provide → serve

### 2.2 HandlerService4-6

**Референс:** axum handlers with 4-6 extractors (covers 95% real handlers).

- [ ] `HandlerService4<E0, E1, E2, E3, Fn, S, Out>`
- [ ] `HandlerService5<E0, E1, E2, E3, E4, Fn, S, Out>`
- [ ] `HandlerService6<E0, E1, E2, E3, E4, E5, Fn, S, Out>`

### 2.3 IntoResponseParts + tuple responses

**Референс:** `axum::response::IntoResponseParts`.

- [ ] Protocol `IntoResponseParts` (contributes headers/status)
- [ ] `(StatusCode, T: IntoResponse)` as IntoResponse
- [ ] `(StatusCode, HeaderMap, T)` as IntoResponse
- [ ] `AppendHeaders([(name, value)])` helper

### 2.4 Option<T> / Result<T, E> extractors

**Референс:** `axum_core::extract::OptionalFromRequestParts`.

- [ ] `OptionalFromRequestParts` protocol
- [ ] `Option<T: FromRequestParts>` extractor (returns nil, not reject)
- [ ] Conformance for all existing extractors

### 2.5 Sse<Stream> structured helper

**Референс:** `axum::response::Sse`.

- [ ] `Sse<S: AsyncSequence>` response type
- [ ] `KeepAlive` configuration
- [ ] Event formatting (data/event/id/retry fields)

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

- [ ] Port matchit path trie
- [ ] O(path-length) matching

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
| `throws ExtractionRejection` вместо `Result<Self, Rejection: IntoResponse>` | Swift `Result.Failure: Error` конфликтует с `IntoResponse` |
| SO_REUSEPORT multi-listener (не single) | Swift не имеет work-stealing runtime |
| `Router<S>` state at init (не `with_state` post-registration) | Будет исправлено в Tier 2.1 |
| HandlerService0-3 (не variadic generics 0-16) | Swift не имеет variadic async closures |
| `ReadBuffer` class (ARC) вместо `BytesMut` value type | Swift `~Copyable` + `Sendable` конфликтуют |
| `Body` enum (не `BoxBody` trait object) | Swift не имеет trait objects |

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
| 18 | 2026-07-21 | Tier 1 fixes: B1-B5 (ConnectInfo, Json status, Router init, CORS, default shutdown) |
| 19 | — | _Next: Tier 2 (with_state, HandlerService4+, IntoResponseParts, Option<T>)_ |
