# Starlight — Roadmap

## Текущее состояние (commit `957c765`)

### Что готово

- **Архитектура**: thread-per-core, one Task per connection, per-loop SO_REUSEPORT (H2O pattern)
- **I/O backend**: на Linux — **custom io_uring reactor** (`CStarlightLinux` raw-syscall C-шим + `IOUringExecutorLoop` — собственный `SerialExecutor` на SQE/CQE, без liburing); на macOS — `NIOAsyncChannel`
- **HTTP/1.1 parser**: SWAR byte search, state machine, request line + headers + body
- **Arena allocator**: bump + exponential growth + bulk reset (3.2× faster than heap)
- **RequestContext (~Copyable)**: arena, method, path, params, headers (lazy HeaderView), body
- **Router**: sync + async dispatch, path params, middleware (sync-only)
- **HandlerKind**: conditional sync/async — sync = direct call, async = `await` inline
- **Body parsing**: Content-Length detection, body collection в arena
- **Security**: 6 fixes (dangling pointers, DoS, race prevention, docs)
- **Pipelining**: feed/tryParse split — корректная обработка multiple requests per TCP packet

### Реальный throughput (12-core, loopback, wrk)

| Endpoint | req/s | per core |
|---|---|---|
| http / | 260K | ~22K |
| router / | 244K | ~20K |
| router /users/42 | 239K | ~20K |

### Сравнение с конкурентами (loopback, hello-world)

| Framework | req/s | Starlight vs |
|---|---|---|
| Hummingbird 2 | ~150K | **1.7× faster** |
| Go net/http | ~200-300K | parity |
| Go fasthttp | ~500K | below |
| Rust axum | ~400-500K | below |
| C H2O | ~700-900K | below |

### Тесты: 78/78 (+ 1 flaky EventLoopExecutor)

---

## План развития

### Phase 4 (продолжение) — Production readiness

#### 4.2 — TLS

**Статус**: не начато (зависимость `swift-nio-ssl` удалена из Package.swift — не использовалась)
**Сложность**: Low
**Время**: ~2 часа

> Примечание: `NIOSSL` ранее числился в зависимостях «про запас», но ни одного
> `import NIOSSL` в `Sources/` не было. Удалён в рамках очистки. Когда TLS
> понадобится — вернуть `swift-nio-ssl` обратно и реализовать по плану ниже.

```swift
// TLSConfig struct
public struct TLSConfig: Sendable {
    public let certificatePath: String
    public let privateKeyPath: String
}

// В childChannelInitializer:
channel.eventLoop.makeCompletedFuture {
    if let tls = tlsConfig {
        try channel.pipeline.syncOperations.addHandler(
            NIOSSLServerHandler(context: sslContext)
        )
    }
    return try NIOAsyncChannel(wrappingChannelSynchronously: channel, ...)
}
```

**Задачи**:
- [ ] TLSConfig struct в новом файле `Sources/StarlightServer/TLSConfig.swift`
- [ ] NIOSSLContext creation из PEM files
- [ ] Интеграция в `StarlightServer.start(tls:)`
- [ ] Тест: HTTPS через curl
- [ ] Замер: TLS overhead

#### 4.3 — Result-builder DSL

**Статус**: не начато
**Сложность**: Low
**Время**: ~2 часа

```swift
let router = Router {
    GET("/health") { _ in .plaintext("ok") }
    Group("/api/v1") {
        GET("/users") { request async in .json(try await db.list()) }
        GET("/users/:id") { request async in ... }
        POST("/users") { request async in ... }
    }
}
```

**Задачи**:
- [ ] `@resultBuilder RouteBuilder` в новом файле `Sources/Starlight/RouterBuilder.swift`
- [ ] Helper functions: `GET`, `POST`, `PUT`, `DELETE`, `Group`
- [ ] Тесты: declarative routes
- [ ] Замер: DSL vs imperative API (должно быть 0% overhead — compile-time only)

#### 4.4 — Polish + v0.1.0

**Статус**: не начато
**Время**: ~3 часа

**Задачи**:
- [ ] README с quickstart
- [ ] DocC documentation
- [ ] Benchmark vs Hummingbird 2 на идентичной конфигурации
- [ ] Fix flaky EventLoopExecutor test
- [ ] Tag `v0.1.0`

---

### Phase 5 — Performance deep-dive

#### 5.1 — Профилирование

**Цель**: найти реальные bottleneck'и через `perf record`

**Задачи**:
- [ ] Запустить `perf record` под wrk нагрузкой
- [ ] Определить top-10 hot functions
- [ ] Проверить: NIO overhead, ARC traffic, allocator contention
- [ ] Сравнить profile с fasthttp/axum

#### 5.2 — Custom io_uring reactor (Linux) ✅ Готово

**Статус**: реализовано, primary backend на Linux

Реализовано без liburing — через raw syscalls (`__NR_io_uring_setup=425` и др.)
с корректными acquire/release барьерами, зеркалирующими liburing 2.7:

- `Sources/CStarlightLinux/` (~672 LOC C): UAPI-заголовок io_uring + `shim.c`
  с `sl_ring_init` (mmap SQ/CQ/SQEs, `IORING_FEAT_SINGLE_MMAP`), `sl_get_sqe`,
  `sl_submit`, `sl_peek_cqe`, `sl_wait_cqe`, сокет-хелперы (`sl_listen` с
  SO_REUSEPORT, `sl_accept4`, `sl_pin_to_cpu`).
- `Sources/StarlightServer/IOUringExecutorLoop.swift` (~541 LOC Swift):
  собственный `SerialExecutor` (SE-0392) поверх SQE/CQE, `ConnectionActor` с
  `nonisolated unownedExecutor` (пиннинг к io_uring-треду), async `readAsync`/
  `writeAsync` через continuation'ы + wakeup через `eventfd`. Опкоды:
  accept / recv / send / poll.

**Что заработало благодаря этому:**
- thread-per-core без хопов в global concurrent pool (флаг
  `NonisolatedNonsendingByDefault` теперь реально нагружен).
- backendName = `"io_uring"` на Linux (`StarlightBenchmark/main.swift`).

**Задачи**:
- [x] Исследовать Swift io_uring bindings (выбран raw syscall вместо liburing)
- [x] Prototype: custom EventLoop на io_uring
- [ ] Benchmark vs NIOAsyncChannel (сравнительных цифр пока нет — оставить на Phase 5.1)

#### 5.3 — Per-connection response buffer pool

**Цель**: убрать `ByteBufferAllocator().buffer()` per response

**Задачи**:
- [ ] Pre-allocate response buffer в connection handler init
- [ ] Reuse через `clear()` между requests
- [ ] Benchmark: убрать allocation overhead

#### 5.4 — Radix trie router

**Цель**: O(path length) matching для apps с 50+ routes

**Задачи**:
- [ ] Implement radix trie (matchit-style)
- [ ] Benchmark: linear vs trie на 3 / 10 / 50 / 100 routes
- [ ] Если win > 5% на 10+ routes — заменить linear search

#### 5.5 — SIMD HTTP parser

**Цель**: ускорить byte search через SIMD16<UInt8>

**Задачи**:
- [ ] Profile: какую долю CPU занимает byte search
- [ ] Если > 15% — implement SIMD path
- [ ] Benchmark SWAR vs SIMD на реальных headers

---

### Phase 6 — Feature completeness

#### 6.1 — Async middleware

**Статус**: middleware сейчас bypass для async handlers
**Цель**: generic `protocol Middleware` с `associatedtype`

```swift
router.get("/users/:id") { ctx async in ... }
// middleware должен работать и для async handlers
```

#### 6.2 — Chunked Transfer-Encoding

**Статус**: не поддерживается
**Цель**: `Transfer-Encoding: chunked` для streaming uploads

#### 6.3 — WebSocket support

**Цель**: `ws://` protocol upgrade, real-time bidirectional

#### 6.4 — HTTP/2

**Цель**: multiplexing, HPACK, server push

#### 6.5 — Static file serving

**Цель**: `sendfile(2)` zero-copy, `ETag`, `Range` requests

#### 6.6 — Graceful shutdown

**Цель**: signal pipe, drain in-flight requests, clean exit

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
- Docker image
- Kubernetes health checks
- systemd unit file

---

## Архитектурные решения (зафиксированные)

1. **One Task per connection** — async handlers inline (не Task-per-request); на Linux executor — io_uring, на macOS — NIOAsyncChannel
2. **Conditional sync/async** — sync handler = zero overhead, async handler = `await` inline
3. **Arena allocator** — per-request bump, bulk reset между keep-alive requests
4. **HeaderView lazy** — один arena allocation для header block, subscript scans on demand
5. **Params array-backed** — `[(name, value)]` вместо Dictionary
6. **Feed/tryParse split** — bytes добавляются один раз, парсинг в loop для pipelining
7. **Per-loop SO_REUSEPORT** — kernel-balanced accept (H2O pattern)
8. **Response staging** — fresh ByteBuffer per response (no COW on shared storage)
9. **Custom io_uring `SerialExecutor` (Linux)** — raw syscalls без liburing, `ConnectionActor` пиннится к io_uring-треду через `nonisolated unownedExecutor`

## Архитектурные долги

1. **EventLoopExecutorCache** — global static, не очищается. Решить в Phase 5 (per-group cache)
2. **Middleware + async** — middleware bypass для async handlers. Решить в Phase 6.1
3. **Chunked encoding** — не детектится. Решить в Phase 6.2
4. **Handler throw** — handler signature не `throws`, developer должен `do/catch`. Документировать
5. **Partial-read testing** — partial-read fix добавлен, но не протестирован на real multi-packet requests
