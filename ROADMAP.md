# Starlight — Roadmap

## Текущее состояние

**Production-ready HTTP/1.1 framework** для Swift 6.2+, построенный по
модели Tokio/H2O: thread-per-core, one Task per connection, zero unsafe
public APIs.

### Архитектура

- **Connection model**: Tokio-style — per-connection Task через
  `Task(executorPreference:)` (SE-0431 `TaskExecutor`). State owned by
  Task frame, no per-connection actors, no shared mutable state.
- **I/O backends**: epoll (default на Linux, через `StarlightPoll`),
  io_uring (опционально через `StarlightIORing`), NIO (macOS + fallback).
  Все три бэкенда используют один и тот же codec dispatch path.
- **HTTP/1.1 parser**: SWAR byte search, state machine, принимает
  `Span<UInt8>` (SE-0447, memory-safe borrowing contract).
- **Codec**: `~Copyable struct`, owned exclusively per-connection Task.
  Zero heap allocation, zero ARC traffic, no `@unchecked Sendable`.
- **Router**: type-state pattern (`RouterBuilder` → `Router`). Builder
  не `Sendable` (compile-time гарантия single-threaded registration);
  `Router` immutable `Sendable` (safe to share между event loops).
- **Handler**: `throws` → uncaught error становится 500 (connection
  closes). Middleware pre-composed at build time — zero per-request
  overhead.
- **Query string**: `QueryView` с URL-decode (`%XX`, `+`→space) и
  UTF-8 (кириллица, CJK, emoji — raw и %-encoded).
- **Safety audit**: 0 unsafe public APIs. 7 `@unchecked Sendable`
  (все — custom executors и server lifecycle, как `DispatchQueue`).

### Throughput (12-core AMD 5600H, loopback, wrk -t12 -c256 -d10s)

| Endpoint | req/s | per core |
|---|---|---|
| `/` (static, pre-cached) | ~322K | ~27K |
| `/users/42` (dynamic, params + alloc) | ~267K | ~22K |

### Сравнение с конкурентами (loopback, hello-world)

| Framework | req/s | Starlight vs |
|---|---|---|
| Hummingbird 2 | ~150K | **2.1× faster** |
| Go net/http | ~200-300K | **parity / faster** |
| Go fasthttp | ~500K | below |
| Rust axum | ~400-500K | below |
| C H2O | ~700-900K | below |

### Тесты: 119/119 passed

---

## Архитектурные решения (зафиксированные)

1. **Tokio-style connection model** — `Task(executorPreference: eventLoop)`
   пиннит Task к loop's executor напрямую (SE-0431 `TaskExecutor`).
   State на Task frame (fd, read buffer, codec). No per-connection actor.
2. **Codec `~Copyable struct`** — эксклюзивное владение, no copy, no ARC.
   Constructed в Task, consumed при exit.
3. **Router type-state** — `RouterBuilder` (mutable, !Sendable) → `Router`
   (immutable, Sendable). Compile-time гарантия thread safety.
4. **Handler `throws`** — uncaught error → 500 Internal Server Error,
   connection closes. Error-handling middleware (future) для custom
   error responses.
5. **Parser `Span<UInt8>`** — memory-safe borrowing (SE-0447).
   `~Copyable & ~Escapable` — компилятор гарантирует no-copy, no-escape.
6. **`tryParse()` + `dispatchAsync()`** — единый dispatch path для всех
   бэкендов. Sync handler = zero async overhead; async handler = один
   continuation hop.
7. **Per-loop SO_REUSEPORT** — kernel-balanced accept (H2O pattern).
8. **Feed/tryParse split** — bytes добавляются один раз, парсинг в loop
   для pipelining.
9. **HeaderView / QueryView** — lazy on-demand byte-walking над COW
   ByteBuffer. Zero allocation если handler не читает headers/query.
10. **SWAR byte search** — `SearchAlgorithm.findByte` для `\n`, `:`, `?`,
    `&`, `=`. Работает через `Span` overload (zero-allocation bridge).

---

## План развития

### Phase 4 — Production readiness (продолжение)

#### 4.1 — Graceful shutdown

**Статус**: частично (shutdown корректно drain'ит Tasks и закрывает fd,
но нет signal-driven drain in-flight requests).
**Время**: ~2 часа.

**Задачи**:
- [ ] Signal handler (SIGTERM/SIGINT) → drain in-flight requests.
- [ ] Timeout для drain (например, 30 сек → force close).
- [ ] Тест: graceful shutdown под нагрузкой.

#### 4.2 — TLS

**Статус**: не начато.
**Время**: ~2 часа.

**Задачи**:
- [ ] `TLSConfig` struct.
- [ ] NIOSSLContext creation из PEM files.
- [ ] Интеграция в `StarlightServer.start(tls:)`.
- [ ] Тест: HTTPS через curl.

#### 4.3 — Polish + v0.1.0

**Задачи**:
- [ ] README с quickstart.
- [ ] DocC documentation.
- [ ] Benchmark vs Hummingbird 2 на идентичной конфигурации.
- [ ] Tag `v0.1.0`.

---

### Phase 5 — Performance

#### 5.1 — Профилирование

**Цель**: найти bottleneck'и через `perf record`.

**Задачи**:
- [ ] `perf record` под wrk нагрузкой.
- [ ] Top-10 hot functions.
- [ ] Сравнить с fasthttp/axum profile.

#### 5.2 — Radix trie router

**Цель**: O(path length) matching для apps с 50+ routes.

**Задачи**:
- [ ] Implement radix trie (matchit-style).
- [ ] Benchmark: linear vs trie на 3 / 10 / 50 / 100 routes.
- [ ] Если win > 5% на 10+ routes — заменить linear search.

#### 5.3 — SIMD HTTP parser

**Цель**: ускорить byte search через SIMD16<UInt8>.

**Задачи**:
- [ ] Profile: какую долю CPU занимает byte search.
- [ ] Если > 15% — implement SIMD path.
- [ ] Benchmark SWAR vs SIMD.

#### 5.4 — IORingExecutorLoop accept path

**Статус**: IORingExecutorLoop использует отдельный accept-thread с `poll(2)`.
EpollExecutorLoop уже использует `registerWatch` (level-triggered
accept4-drain). Унифицировать io_uring backend.
**Время**: ~4 часа (высокий риск).

---

### Phase 6 — Feature completeness

#### 6.1 — Chunked Transfer-Encoding

**Статус**: не поддерживается (reject с 400).
**Цель**: `Transfer-Encoding: chunked` для streaming uploads.

#### 6.2 — WebSocket support

**Цель**: `ws://` protocol upgrade, real-time bidirectional.

#### 6.3 — HTTP/2

**Цель**: multiplexing, HPACK, server push.

#### 6.4 — Static file serving

**Цель**: `sendfile(2)` zero-copy, `ETag`, `Range` requests.

#### 6.5 — Error-handling middleware

**Цель**: `Middleware.init(catch:)` для custom error responses
поверх typed `HTTPError`.

---

### Phase 7 — Ecosystem

#### 7.1 — JSON convenience
```swift
HTTPResponse.json(user)  // Encodable → JSON → ByteBuffer
```

#### 7.2 — Template rendering
```swift
HTTPResponse.html(template.render(context))
```

#### 7.3 — OpenAPI / Swagger generation

#### 7.4 — Testing utilities
```swift
let app = StarlightApp()
let response = try await app.test(.GET, "/users/42")
#expect(response.status == .ok)
```

#### 7.5 — Deployment
- Docker image.
- Kubernetes health checks.
- systemd unit file.

> **Контейнерная совместимость io_uring:**
> io_uring работает в Docker/Podman ≥20.10. На старых runtime или в
> залоченных sandbox'ах (gVisor) io_uring может быть недоступен — тогда
> автоматический fallback на epoll (default Linux backend). Для SQPOLL
> (если будет добавлен опционально): `--cap-add SYS_RAWIO --ulimit
> memlock=-1:-1`.

---

## Архитектурный аудит (завершён)

Полный аудит кодовой базы проведён и зафиксирован в серии коммитов
(`4d25052`–`a337037`). Результаты замеров — в `bench/results/`.

| Phase | Commit | Эффект |
|-------|--------|--------|
| A-1 Retain cycles | `4d25052` | fd/pthread leaks устранены |
| A-2 Shutdown drain | `88b7f31` | Tasks не висят, no double-close |
| A-3 Dead code cleanup | `7bd2cd9` | CL branch, invariant documented |
| A-4 Multi-read precondition | `cf0c723` | Continuation leak detection |
| P05 QueryView | `ce1b83a` | URL query с UTF-8 + URL-decode |
| A-7 Router type-state | `fa690c9` | Compile-time thread safety |
| A-8 Unify codec dispatch | `6db3eb0` | Один путь для всех бэкендов |
| A-11 Handler throws | `d30a248` | throws → 500, -1% throughput |
| P22 Connection model | `6ddaeb6` | Tokio-style, **+11.4%** |
| P12 Codec ~Copyable | `7e7a8f9` | Zero heap alloc, compile-time safety |
| P9 Remove dead code | `8532845` | -512 B/conn, unified dispatch |
| P23 Parser Span | `bb337c4` | Memory-safe parser API |
| P24 Unsafe API elimination | `a337037` | **0 unsafe public APIs** |

**Кумулятивный throughput gain: +17.5%** (274K → 322K req/s).
