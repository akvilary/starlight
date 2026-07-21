# Starlight — Roadmap

Direct port of Rust's [axum](https://github.com/tokio-rs/axum) to Swift.
This file tracks what's done, what's next, and where we're heading.
The single source of truth for any architectural decision is the axum
source tree + hyper source tree; deviations happen only when Swift's
type system or runtime model doesn't allow a literal port.

## Текущее состояние

| Компонент | Статус |
|---|---|
| `../http` package (port of `http` crate) | ✅ 5/5 tests |
| `../hyper` package (port of `hyper::proto::h1`) | ✅ 7/7 tests |
| `Starlight` (axum umbrella) — Tower/Core/Routing/Extractors/Middleware/Server | ✅ 10/10 tests |
| HTTP/1.1 end-to-end pipeline | ✅ работает (`curl` отвечает) |
| Бенчмарк | ~260K req/s release (loopback, 12-core AMD 5600H, wrk -t12 -c100 -d3s) |
| Graceful shutdown | ❌ |
| Streaming bodies / chunked TE | ❌ |
| Router nesting / layers | ❌ |
| TLS | ❌ |
| HTTP/2 | ❌ |
| WebSocket | ❌ |

## Архитектурный фундамент (зафиксирован)

- **8 модулей** mirror axum workspace 1:1
- **`Worker` actor** (без `@unchecked Sendable`) с `unownedExecutor` → `PollEventLoop`
- **Task-per-connection** (не per-accept, не per-request) — амортизируется по keep-alive
- **`PollEventLoop.drainJobs()`** — `while` loop, не single-pass (Swift Task = 2 jobs: setup + body)
- **`PollEventLoop.checkIsolated()`** — переопределён через `pthread_self == loopThreadId` для sync watch callbacks

---

## Phase 1 — Production HTTP/1.1

**Цель:** Сервер, готовый к реальным deployment'ам.

**Время:** ~16 часов (4-5 сессий).

### 1.1 Graceful shutdown

**Референс:** `axum::serve::WithGracefulShutdown`.

**Задачи:**
- [ ] Signal handler (SIGTERM / SIGINT) → drain in-flight requests.
- [ ] `serve(...).withGracefulShutdown(signal)` API.
- [ ] Timeout для drain (default 30s → force close).
- [ ] Тест: shutdown под wrk нагрузкой, все in-flight запросы дорабатывают.

**Acceptance:** `kill -TERM <pid>` не рвёт активные запросы.

**Время:** ~3 часа.

### 1.2 Streaming bodies

**Референс:** `hyper::body::Body` + `http_body::Frame`.

**Задачи:**
- [ ] `Body` enum: `.empty` / `.buffered([UInt8])` / `.stream(AsyncSequence)`.
- [ ] Chunked Transfer-Encoding decoder (port of `hyper::proto::h1::decode::Decoder::chunked`).
- [ ] Chunked Transfer-Encoding encoder.
- [ ] `Response<Body>` умеет писать streaming bodies.
- [ ] SSE endpoint example.

**Acceptance:** Streaming echo endpoint корректно отдаёт chunks.

**Время:** ~6 часов.

### 1.3 Router: nesting + layers

**Референс:** `axum::routing::Router::{nest, layer, route_layer, with_state}`.

**Задачи:**
- [ ] `Router.nest("/api", nestedRouter)` — merge routes under prefix.
- [ ] `Router.layer(...)` — применить middleware ко всем routes.
- [ ] `Router.route_layer(...)` — применить только к конкретным routes.
- [ ] `Router.with_state(_:)` — конвертация `Router<S>` → `Router<S2>`.
- [ ] Тесты: composition, ordering, nested state extraction.

**Acceptance:** REST API example с nested routes и layer composition.

**Время:** ~4 часа.

### 1.4 Дополнительные extractors

**Референс:** `axum::extract::{Bytes, Form, TypedHeader, ConnectInfo, Request, DefaultBodyLimit}`.

**Задачи:**
- [ ] `Bytes` — raw body bytes (без декодинга).
- [ ] `Form<T>` — `application/x-www-form-urlencoded` → `T`.
- [ ] `TypedHeader<T>` — typed header via protocol.
- [ ] `ConnectInfo<Addr>` — peer address.
- [ ] `Request<Body>` — whole request as extractor.
- [ ] `DefaultBodyLimit` — ограничение размера тела.

**Acceptance:** JSON API example со всеми extractors.

**Время:** ~3 часа.

---

## Phase 2 — Performance parity

**Цель:** Догнать axum (Rust) по throughput на идентичных тестах.

**Время:** ~12 часов (3-4 сессии).

### 2.1 SWAR byte search

**Референс:** `hyper::proto::h1::io` uses `bytes::Find` (SWAR memchr).

**Задачи:**
- [ ] Port SWAR `findByte` для `\r`, `\n`, `:`, ` ` — 8 байт за итерацию.
- [ ] Применить в `H1Decoder.findHeaderBlockEnd` + `findByte`.
- [ ] Бенчмарк до/после.

**Время:** ~3 часа.

### 2.2 Zero-copy accumulator

**Референс:** hyper's per-conn `BytesMut` accumulator + `Bytes` views.

**Задачи:**
- [ ] Один byte buffer на соединение, переиспользуется через `discardReadBytes`.
- [ ] `Request.body` — view (offset+length) над accumulator, не copy.
- [ ] Бенчмарк alloc/req до/после.

**Время:** ~4 часа.

### 2.3 writev multi-buffer output

**Референс:** hyper's `writev(2)` coalescing of header + body buffers.

**Задачи:**
- [ ] Response: separate header + body ByteBuffers.
- [ ] `writev(2)` через libc wrapper в `CLinuxExt`.
- [ ] Бенчмарк: 1 syscall vs 2 syscalls per request.

**Время:** ~3 часа.

### 2.4 `~Copyable` + `@_specialize`

**Референс:** hyper's `Conn: !Clone` + tower's monomorphised services.

**Задачи:**
- [ ] `H1Decoder: ~Copyable`, `H1Encoder: ~Copyable`.
- [ ] `@_specialize` на `BoxService.call` где компилятор может инлайнить.
- [ ] Profile через `perf record`, найти hot indirect calls.
- [ ] Цель: ≤ 10% gap vs axum на идентичной конфигурации.

**Время:** ~2 часа.

---

## Phase 3 — Tower middleware ecosystem

**Цель:** Перенести основные middleware из `tower-http` + `axum::middleware`.

**Время:** ~20 часов (5 сессий).

### 3.1 CompressionLayer

**Референс:** `tower_http::compression::*`.

- [ ] Gzip / Deflate / Brotli encoders (zlib / libbz2).
- [ ] Auto-select по `Accept-Encoding`.
- [ ] Skip маленьких тел (< 256 bytes).
- [ ] Тесты + benchmark overhead.

**Время:** ~6 часов.

### 3.2 TraceLayer

**Референс:** `tower_http::trace::*`.

- [ ] Request / response logging (method, path, status, duration).
- [ ] Hooks: `on_request`, `on_response`, `on_failure`.
- [ ] Span IDs для distributed tracing.

**Время:** ~4 часа.

### 3.3 CorsLayer

**Референс:** `tower_http::cors::*`.

- [ ] Preflight (`OPTIONS`) handling.
- [ ] `Access-Control-Allow-*` headers.
- [ ] Config: allowed origins, methods, headers, max-age.

**Время:** ~3 часа.

### 3.4 TimeoutLayer + RateLimitLayer

**Референс:** `tower::timeout::Timeout` + `tower::limit::rate`.

- [ ] Per-request timeout (default 30s) → 504.
- [ ] Token bucket per-IP → 429.
- [ ] Cleanup отменённых Tasks.

**Время:** ~7 часов.

---

## Phase 4 — HTTP protocol features

**Цель:** Полная поддержка современных HTTP фичей.

**Время:** ~24 часа (6-8 сессий).

### 4.1 HTTP/2

**Референс:** `hyper::proto::h2`.

- [ ] HPACK header compression.
- [ ] Stream multiplexing.
- [ ] Server push (deprecated but supported).
- [ ] ALPN negotiation (через TLS backend).

**Время:** ~12 часов.

### 4.2 WebSocket

**Референс:** `axum::extract::ws` + `tungstenite`.

- [ ] RFC 6455 framing.
- [ ] `ws://` upgrade via `Connection: Upgrade`.
- [ ] `WebSocket` extractor.
- [ ] Ping/pong, close frames.

**Время:** ~6 часов.

### 4.3 TLS

**Референс:** `hyper-util::rt::TLS` + `rustls`.

- [ ] NIOSSL или BoringSSL integration.
- [ ] `TLSConfig` struct (PEM files).
- [ ] ALPN для HTTP/2 negotiation.
- [ ] HTTPS endpoint example.

**Время:** ~6 часов.

### 4.4 Static file serving

**Референс:** `tower-http::services::ServeDir` + `tokio::fs`.

- [ ] `sendfile(2)` zero-copy.
- [ ] `ETag`, `Last-Modified`.
- [ ] `Range` requests.
- [ ] MIME type detection.

**Время:** ~4 часа (максимально после HTTP/1.x features).

---

## Phase 5 — Advanced performance

**Цель:** Догнать и превзойти Rust axum где позволяет Swift runtime.

**Время:** ~17 часов (4-5 сессий).

### 5.1 Radix trie router

**Референс:** axum's use of [`matchit`](https://github.com/ibraheemdev/matchit).

- [ ] Port matchit path trie.
- [ ] Static + dynamic segments in one tree.
- [ ] Benchmark: linear vs trie на 3/10/50/100 routes.

**Время:** ~8 часов.

### 5.2 SIMD HTTP parser

**Референс:** `simdjson` / `picohttpparser` SWAR+SIMD paths.

- [ ] Profile через `perf record`: % CPU в byte search.
- [ ] Если > 15%: SIMD128 path через `SIMD16<UInt8>`.
- [ ] Бенчмарк SWAR vs SIMD.

**Время:** ~6 часов.

### 5.3 Connection pooling + HTTP keepalive tuning

**Референс:** hyper's `pool` module.

- [ ] Per-host connection pool для outbound clients.
- [ ] Idle connection timeout.
- [ ] Max connections per host.

**Время:** ~3 часа.

---

## Phase 6 — Ecosystem & v0.1.0

**Цель:** Готовый к production v0.1.0 release.

**Время:** ~16 часов (4-5 сессий).

### 6.1 Documentation

- [ ] Doc comments на всех public API.
- [ ] DocC catalog с tutorials.
- [ ] Hosted docs на GitHub Pages.

**Время:** ~4 часа.

### 6.2 Examples (как `axum/examples/`)

- [ ] `Examples/hello-world/` — minimal.
- [ ] `Examples/rest-api/` — CRUD with JSON.
- [ ] `Examples/middleware/` — from_fn + layers.
- [ ] `Examples/sse/` — Server-Sent Events.
- [ ] `Examples/websocket/` — chat.
- [ ] `Examples/file-upload/` — multipart.

**Время:** ~6 часов.

### 6.3 TestClient

**Референс:** `axum::test::TestClient`.

- [ ] `TestClient` — `router.get("/").expect(.ok)` ergonomics.
- [ ] Mock TCP / in-memory transport для unit-тестов.
- [ ] `swift test` запускает все examples.

**Время:** ~3 часа.

### 6.4 v0.1.0 release

- [ ] README с quickstart + benchmarks.
- [ ] CHANGELOG.md.
- [ ] CI на GitHub Actions (Linux + macOS).
- [ ] Tag `v0.1.0` на git.
- [ ] Announcement.

**Время:** ~3 часа.

---

## Принципы

1. **axum 1:1** — каждая абстракция имеет соответствие в axum source.
   Если в axum нет — не добавляем без сильной причины.
2. **Hot path — zero-allocation** после первого keep-alive запроса.
3. **Swift idioms где Rust literal не переносится** — `throws` вместо
   `Result`, `~Copyable` где это покупает производительность, `actor`
   для state isolation.
4. **Tower-compatible** — любой middleware под `Service` / `Layer`
   работает без HTTP-specific shortcut'ов.
5. **Тесты обязательны** для каждого PR в Phase 1-3.
6. **Benchmarks после каждой фазы** — regression если > 5% drop.

## Session log

| # | Дата | Что сделано |
|---|---|---|
| 1 | 2026-07-21 | Skeleton: 8 axum modules, protocols, 15 tests. `729c5a6`. |
| 2 | 2026-07-21 | ROADMAP dropped, reference axum directly. `aaf682f`. |
| 3 | 2026-07-21 | Extracted `../http` + `../hyper` packages. `f9bc525`. |
| 4 | 2026-07-21 | Working HTTP server, Worker actor, 136K req/s. `5bec2ed`. |
| 5 | 2026-07-21 | Phase 1.1: graceful shutdown via SIGINT/SIGTERM + drain timeout. `280c554`. |
| 6 | 2026-07-21 | Phase 1.2: streaming bodies + chunked TE (in + out). `8d917f3`. |
| 7 | 2026-07-21 | Phase 1.3: Router.nest + merge + layer + route_layer. `03cd521`. |
| 8 | 2026-07-21 | Phase 1.4: Bytes + Form + ConnectInfo + RawRequest extractors. |
| 9 | 2026-07-21 | Phase 2.1: SWAR byte search (hyper `ByteSearch.swift`). |
| 10 | — | _Phase 2.2 start (Zero-copy accumulator)_ |
