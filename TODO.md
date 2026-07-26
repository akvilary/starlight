# Starlight TODO — путь к Swift 6.2 reference

---

## Выполнено (Phase A — Critical correctness)

| Пункт | Описание | Коммит |
|---|---|---|
| A1 | TimeoutLayer error swallowing → 500 вместо 504 | `b6ec637` |
| A2 | Drain timeout hang (withTimeout с withTaskGroup) | `b6ec637` |
| A3 | DefaultBodyLimit enforcement во всех body-extractor'ах | `683ad8c` |
| A4 | Body.collect проверяет лимит ДО append | `6bac98e` |
| A5 | Route merging для одного path | `bbd5203` |
| A6 | Percent-decoding path parameters | `a7d721e` |
| A7 | PathParams.decodeNil → !contains(key) | `578b728` |
| A8 | Query scalar decode (StringKeyedDecoder, вместо JSON round-trip) | `8643303` |
| A10 | writeAll/accept4 EINTR/EAGAIN handling | `c25078d` |
| A11 | sigaction + SA_RESTART + pthread_sigmask unblock | `f3cdd0c` |
| A12 | ServeDir path traversal (realpath canonicalization) | `3c0b394` |
| A17 | Bare CR/LF rejection + TE exact-token matching | `3f6e454` |
| A18 | Chunked trailer scan для \r\n\r\n | `3f6e454` |
| A20 | HEAD/204/304 body suppression в Encoder | `3f6e454` |
| A25 | HTTP/1.1 missing Host → 400 | `3f6e454` |
| A26 | CL+TE conflict → 400 | `3f6e454` |

Также выполнено:
- MIO v0.2.0: Swift 6.2 hardening, Events: ~Copyable, epoll_pwait2, EPOLLEXCLUSIVE
- IntegrationClient: real-TCP тестовая инфраструктура (11 integration tests)
- Generic `<B>` удалён из Request/Response/RequestParts

Бенчмарк после всех фиксов: ~290K req/s (без регрессии)

---

## Оставшиеся пункты Phase A

### A9. PollEventLoop lazy executor cache — data race
- **Файл:** `Sources/StarlightPoll/PollEventLoop.swift:122-141`
- **Проблема:** `_cachedExecutor` / `_cachedTaskExecutor` — `var` на `@unchecked Sendable` классе, check-then-set из nonisolated методов.
- **Фикс:** `let` в init, или atomic guard.

### A13. Compression buffer overflow risk
- **Файл:** `Sources/StarlightMiddleware/Compression.swift:85`
- **Проблема:** `inputLen + 64` — zlib требует `inputLen * 1.001 + 64`.
- **Фикс:** `deflateBound` или формула выше.

### A14. Compression Vary через insert (cache poisoning)
- **Файл:** `Sources/StarlightMiddleware/Compression.swift:107`
- **Проблема:** `insert(.vary, "Accept-Encoding")` затирает существующий Vary.
- **Фикс:** Append-семантика.

### A15. CORS bugs (preflight, Vary, default, origin matching)
- **Файл:** `Sources/StarlightMiddleware/Cors.swift`
- **Проблемы:** каждый OPTIONS = preflight (нужны Origin+ACRM); нет Vary: Origin; default = `*`; origin byte-exact без нормализации порта.
- **Фикс:** Полный rewrite preflight detection + Vary + restrictive default.

### A16. RateLimit global fallback
- **Файл:** `Sources/StarlightMiddleware/RateLimit.swift:104-107`
- **Проблема:** Default keyExtractor fold'ит в `"global"` когда ConnectInfo нет.
- **Фикс:** Требовать явный keyExtractor.

### A19. parseHex overflow + total body cap
- **Файл:** `hyper/Sources/Hyper/Proto/H1/Decoder.swift:470-485`
- **Проблема:** `result * 16 + digit` без overflow check. Нет отдельного body cap.
- **Фикс:** Overflow-safe parseHex + `maxBodyBytes`.

### A21. Hop-by-hop headers не strip'ятся
- **Файл:** `Decoder.swift`, `Encoder.swift`
- **Проблема:** Connection/Keep-Alive/TE/Trailer/Upgrade leak'ают.
- **Фикс:** Normalisation pass после parse, перед encode.

### A22. SWAR wrong на big-endian
- **Файл:** `hyper/Sources/Hyper/Proto/H1/ByteSearch.swift:65-70`
- **Проблема:** `trailingZeroBitCount/8` правильно только на LE.
- **Фикс:** `#if _endian(big)` branch.

### A23. Extensions @unchecked Sendable + mutable Dictionary
- **Файл:** `http/Sources/HTTP/Request.swift:72-112`
- **Проблема:** Dictionary под `@unchecked Sendable` — гонка при concurrent mutation.
- **Фикс:** Mutex-backed, или COW + freeze-before-cross.

### A24. BodyProtocol.nextFrame бесконечный loop для .buffered
- **Файл:** `http/Sources/HTTP/Body.swift:278-299`
- **Проблема:** Всегда возвращает `.data(b)`, никогда `nil`.
- **Фикс:** Убрать conformance, или сделать Body stateful.

### A27. 100-Continue не реализован
- **Файл:** `Decoder.swift`, `Dispatcher.swift`
- **Проблема:** Клиенты с `Expect: 100-continue` dead-lock'ают.
- **Фикс:** После parse header'ов — написать `HTTP/1.1 100 Continue`.

### A28. H1Dispatcher никогда не feeds decoder; body не пишется
- **Файл:** `hyper/Sources/Hyper/Proto/H1/Dispatcher.swift:72-78, 84-100`
- **Проблема:** Production работает только потому, что Worker обходит dispatcher.
- **Фикс:** Удалить H1Dispatcher как мёртвый путь.

---

## Фаза B — Handler/State model (breaking API change)

### B1. Убрать `associatedtype State` из FromRequestParts/FromRequest
- **Файл:** `Sources/StarlightCore/FromRequest.swift:88-120`
- **Проблема:** Каждый встроенный extractor жестит `typealias State = AnySendable`. HandlerServiceN требует `E0.State == S`.

### B2. withState не доставляет state до handler'ов
- **Файл:** `Sources/StarlightRouting/Router.swift:380-387`

### B3. Удалить мёртвые поля
- `MethodRouter.state`, `Fn` phantom parameter, `bodyAlreadyConsumed` guard

### B4. HandlerService1Body для `(_ body: FromRequest) -> Out`

### B5. HandlerServiceN conform'ит Handler для N=0..6

### B6. Arity 7-16 (codegen или variadic pack)

### B7. consuming-propagating BoxService

### B8. Body не drain'ится при rejection

---

## Фаза C — Worker/Codec production-ready

### C1. IPv6 getPeerAddress
### C2. Listener FD leak (Worker deinit)
### C3. serve() readiness gate не таймаутит
### C4. Slowloris: read timeouts
### C5. Worker actor mailbox contention → Atomic inFlightConns
### C6. writev без [iovec] alloc
### C7. Reuse ConnectInfo per-connection
### C8. Wire ServerTransaction.shouldKeepAlive
### C9. HTTP/1.0 status line
### C10. Signalfd вместо poll (v0.2)
### C11. PollEventLoop.channels nonisolated mutability
### C12. loopThreadId.store(0) теряет jobs
### C13. H1Conn/BufferedIO @unchecked Sendable
### C14-C16. acceptConnection overflow, EPOLLERR, wrapping arithmetic
### C17-C20. Dispatcher lifecycle fixes

---

## Фаза D — Routing/Performance

### D1. Sort dynamicRoutes по specificity (или radix tree)
### D2. route_layer не оборачивает fallback
### D3. MethodRouter.fallback работает для стандартных методов
### D4. nest пропагирует inner fallback
### D5. Удалить RouteId (или wire up)
### D6. Static routes → Dictionary
### D7. 405 Allow header включает HEAD
### D8. No-collapse для `//` в path
### D9-D12. JSONDecoder/Encoder static, Encoder.crlf, byte compare, HeaderMap.insert
### D13. Trace rename → LoggingLayer
### D14-D16. Sse keep-alive + Sendable + Connection header
### D17-D24. Redirect, Form encoder, Host, TestClient, Method enum, EncodedHead

---

## Сделанные замены (история)

- 2026-07-22: Убран generic `<B>` из Request/Response/RequestParts. ~294K req/s.
- 2026-07-26: MIO v0.2.0 — Swift 6.2 hardening + Events: ~Copyable.
- 2026-07-26: IntegrationClient + 11 integration tests.
- 2026-07-26: Codec smuggling fixes A17/A18/A20/A25/A26.
- 2026-07-26: TimeoutLayer + drain timeout fix A1/A2.
- 2026-07-26: DefaultBodyLimit + Body.collect A3/A4.
- 2026-07-26: Route merging A5.
- 2026-07-26: Percent-decode path params A6.
- 2026-07-26: decodeNil fix A7.
- 2026-07-26: Query scalar decode + StringKeyedDecoder A8.
- 2026-07-26: writeAll/accept4 EINTR/EAGAIN A10.
- 2026-07-26: sigaction + SA_RESTART A11.
- 2026-07-26: ServeDir realpath traversal defense A12.
