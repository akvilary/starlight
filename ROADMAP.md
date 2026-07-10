# Starlight — Roadmap

## Текущее состояние (commit `4b8053c`)

### Что готово

- **Архитектура**: NIOAsyncChannel, one Task per connection, per-loop SO_REUSEPORT (H2O pattern)
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

#### 4.2 — TLS via NIOSSL

**Статус**: не начато
**Сложность**: Low
**Время**: ~2 часа

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

#### 5.2 — Custom io_uring reactor (Linux)

**Цель**: убрать NIO overhead, direct epoll/io_uring access

**Задачи**:
- [ ] Исследовать Swift io_uring bindings (liburing через C interop)
- [ ] Prototype: custom EventLoop на io_uring
- [ ] Benchmark vs NIOAsyncChannel
- [ ] Если win > 20% — заменить NIO

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

1. **NIOAsyncChannel** — один Task на connection, async handlers inline (не Task-per-request)
2. **Conditional sync/async** — sync handler = zero overhead, async handler = `await` inline
3. **Arena allocator** — per-request bump, bulk reset между keep-alive requests
4. **HeaderView lazy** — один arena allocation для header block, subscript scans on demand
5. **Params array-backed** — `[(name, value)]` вместо Dictionary
6. **Feed/tryParse split** — bytes добавляются один раз, парсинг в loop для pipelining
7. **Per-loop SO_REUSEPORT** — kernel-balanced accept (H2O pattern)
8. **Response staging** — fresh ByteBuffer per response (no COW on shared storage)

## Архитектурные долги

1. **EventLoopExecutorCache** — global static, не очищается. Решить в Phase 5 (per-group cache)
2. **Middleware + async** — middleware bypass для async handlers. Решить в Phase 6.1
3. **Chunked encoding** — не детектится. Решить в Phase 6.2
4. **Handler throw** — handler signature не `throws`, developer должен `do/catch`. Документировать
5. **Partial-read testing** — partial-read fix добавлен, но не протестирован на real multi-packet requests
