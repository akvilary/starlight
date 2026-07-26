# Starlight TODO

---

## Phase A — Critical correctness ✅ COMPLETE

28 пунктов выполнено. Все коммиты ниже.

| Пункт | Описание | Коммит |
|---|---|---|
| A1 | TimeoutLayer error swallowing → 500 вместо 504 | `b6ec637` |
| A2 | Drain timeout hang (withTimeout + withTaskGroup) | `b6ec637` |
| A3 | DefaultBodyLimit enforcement во всех body-extractor'ах | `683ad8c` |
| A4 | Body.collect проверяет лимит ДО append | `6bac98e` |
| A5 | Route merging для одного path | `bbd5203` |
| A6 | Percent-decoding path parameters | `a7d721e` |
| A7 | PathParams.decodeNil → !contains(key) | `578b728` |
| A8 | Query scalar decode (StringKeyedDecoder) | `8643303` |
| A9 | PollEventLoop executor cache race → fresh struct per call | `17b1636` |
| A10 | writeAll/accept4 EINTR/EAGAIN handling | `c25078d` |
| A11 | sigaction + SA_RESTART + pthread_sigmask unblock | `f3cdd0c` |
| A12 | ServeDir path traversal (realpath canonicalization) | `3c0b394` |
| A13 | Compression buffer size (zlib deflateBound formula) | `3785ebd` |
| A14 | Compression Vary append вместо insert | `ba19633` |
| A15 | CORS preflight detection + Vary: Origin + policy leak | `26ed5d4` |
| A16 | RateLimit keyExtractor → String? + 500 при nil | `cb4074e` |
| A17 | Bare CR/LF rejection + TE exact-token matching | `3f6e454` |
| A18 | Chunked trailer scan для \r\n\r\n | `3f6e454` |
| A19 | parseHex overflow-safe + maxBodyBytes cap | `542d42b` |
| A20 | HEAD/204/304 body suppression в Encoder | `3f6e454` |
| A21 | Hop-by-hop headers stripping (parse + encode) | `6a94a9b` |
| A22 | SWAR big-endian support (byteSwapped) | `ade6a7f` |
| A23 | Extensions Sendable без @unchecked (any Sendable) | `cbf3ace` |
| A24 | BodyProtocol/Frame/SizeHint удалены (dead code) | `7d1d284` |
| A25 | HTTP/1.1 missing Host → 400 | `3f6e454` |
| A26 | CL+TE conflict → 400 | `3f6e454` |
| A27 | Expect: 100-continue support | `7891d69` |
| A28 | H1Dispatcher/HTTP1Builder/H1Conn/BufferedIO удалены | `b75435b` |

Также выполнено:
- MIO v0.2.0: Swift 6.2 hardening, Events: ~Copyable, epoll_pwait2, EPOLLEXCLUSIVE
- IntegrationClient: real-TCP тестовая инфраструктура (11 integration tests)
- Generic `<B>` удалён из Request/Response/RequestParts
- StringKeyedDecoder: reusable decoder для Path/Query/Form

Тесты: 82 total (5 http + 18 hyper + 21 mio + 59 starlight)
Бенчмарк: ~300K req/s (без регрессии за всю Phase A)

---

## Фаза B — Handler/State model (breaking API change)

### B1. Убрать `associatedtype State` из FromRequestParts/FromRequest
- **Файл:** `Sources/StarlightCore/FromRequest.swift`
- **Проблема:** Каждый встроенный extractor жестит `typealias State = AnySendable`. HandlerServiceN требует `E0.State == S`.

### B2. withState не доставляет state до handler'ов
- **Файл:** `Sources/StarlightRouting/Router.swift`

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
- `sockaddr_storage` + `inet_ntop` по `ss_family`

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
### C13. H1Conn/BufferedIO @unchecked Sendable — УДАЛЕНО (A28)
### C14. acceptConnection silently drops over cap
### C15. Worker.handleAccept ignores EPOLLERR/EPOLLHUP
### C16. wrapping arithmetic на counters
### C17-C20. Dispatcher lifecycle — УДАЛЕНО (A28)

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
### D9. JSONDecoder/Encoder как module-level static let
### D10. Encoder.crlf → static let
### D11. ASCII-case-insensitive byte compare для Connection/TE
### D12. HeaderMap.insert → single-pass find+replace
### D13. Trace rename → LoggingLayer
### D14. Sse keep-alive + backpressure
### D15. Sse @unchecked Sendable → proper Sendable constraints
### D16. Sse Connection header (invalid для HTTP/2)
### D17. Redirect.to → 307 вместо 302
### D18. Form encoder не escape'ит &=+%
### D19. Host extractor trusted-proxy gate
### D20. IntegrationClient через real TCP (done, expand tests)
### D21. HandlerServiceN per-dispatch Request reconstruction
### D22. Streaming responses per-chunk flush
### D23. Method as enum
### D24. EncodedHead leak'ает body-write ответственность
