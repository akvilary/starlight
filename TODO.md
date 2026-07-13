# Starlight TODO

Актуальный список багов и недочётов.
Идти сверху вниз по приоритетам. Отмечать `[x]` по завершении.

---

## Блок 0 — Критичные баги (краши / corruption / security) — ✅ ЗАКРЫТ

- [x] **0-1. HTTP Request Smuggling: `Transfer-Encoding: chunked`** — Reject any TE per RFC 7230 §3.3.3. Per-line detection.
- [x] **0-2. Duplicate/conflicting `Content-Length`** — Per-line count tracking. Fast path via subscript.
- [x] **0-3. `parseContentLength` overflow** — Pre-multiply check replaces wrapping `&*`.
- [x] **0-4. `maxRequestBytes`/`maxHeaderCount` not enforced** — Checks in stepRequestLine + stepHeaders.
- [x] **0-5. fd-recycling → CQE misattribution** — Monotonic connId replaces fd in user_data.
- [x] **0-6. `stopped`/`loopThreadId` non-atomic** — `Atomic<Bool>` + `Atomic<UInt>`.
- [x] **0-7. Connections not closed on shutdown** — `drainConnections()`. Underflow guard.
- [x] **0-8. NIO `eventLoopGroup` never shut down** — `syncShutdownGracefully()`.

---

## Блок A — Архитектурные недочёты

- [ ] **A-1. Router — O(N) linear scan** — Либо доставить trie, либо убрать из документации.
- [ ] **A-2. DSL с result-builder отсутствует** — Нет `@resultBuilder`, нет декларативного route API.
- [x] **A-3. `Router.freeze()` data race** — `Atomic<Bool>` + `compareExchange`. Убран из hot path.
- [ ] **A-5. Нет валидации field-name / field-value** — Только наличие `:`. Валидировать token-charset (§3.2.6).
- [ ] **A-6. Нет 405/Allow, HEAD→GET, percent-decoding** — RFC 7231 §6.5.5, §4.1.2.
- [ ] **A-7. Конфликтующие маршруты не детектируются** — Детект коллизий на `add()`.
- [ ] **A-8. Несогласованная нормализация слешей** — `//` коллапсируют безгранично. Единая policy.
- [x] **A-9. ConnectionActor per-connection → per-loop** — 12 аллокаций вместо 100K.
- [x] **A-10. Task hop** — Per-loop actor. Полное устранение требует `Task(executor:)` (SE-0416).
- [x] **A-11. composeOne в routes** — Композиция убрана. routes используется только для routeCount.
- [x] **A-12. CLinuxExt.h без `extern "C"`** — Добавлен guard для C++ consumers.
- [x] **A-13. LinuxSocket port + inet_pton** — `UInt16(exactly:)` range check. inet_pton result verified.

---

## Блок B — Логические баги

- [x] **B-1. Аккумулятор memory leak на keep-alive** — `discardReadBytes()` в `afterDispatch()`.
- [x] **B-2. reset() не чистит responseBuffer** — Анализ: НЕ баг. `plaintext(_:into:)` всегда clear() перед записью. Добавлен regression test.
- [x] **B-3. connectionCount underflow** — Декремент только если removeValue succeeded.
- [x] **B-4. CQE errors silently swallowed** — Production error handling: inflight tracking, orphan recovery, wakeup re-arm, consecutive error threshold (32), cqOverflowEvents в stats. Audit пройден.
- [ ] **B-5. HTTPMethod.other routable** — Запретить `add(.other, ...)`.
- [ ] **B-6. Raw method bytes потеряны** — WebDAV методы теряются.
- [ ] **B-7. HTTPStatus.Hashable включает reasonPhrase** — Hashable только по code.
- [ ] **B-8. Status code не валидируется [100, 599]** — HTTPStatus(0) валидно.
- [ ] **B-9. writeStatusLine расходится с defaultReason** — Единая таблица.
- [x] **B-10. Middleware short-circuit outer after** — Анализ: НЕ баг. Regression test добавлен.
- [ ] **B-11. soReusePort magic number fallback** — rawValue: 15 на других платформах.
- [x] **B-12. Unused fn binding** — `case .async(let fn)` → `case .async`.

---

## Блок C — Performance / zero-allocation

- [ ] **C-1. Header copy: memcpy вместо COW-slice** — copyBlock → clear + writeBytes. COW-slice из аккумулятора.
- [ ] **C-2. HeaderView.values(for:) аллоцирует [String]** — Callback API.
- [x] **C-3. Content-Length lookup материализует String** — Per-line detection. Fast path для 0-1 CL.
- [ ] **C-4. Params() на каждый candidate route** — Вынести из цикла.
- [ ] **C-5. RouteSegment.literal хранит данные дважды** — text не читается на hot path.
- [ ] **C-6. Route.pattern: String мёртвое хранилище** — Удалить или CustomStringConvertible.
- [ ] **C-7. Побайтовое сравнение вместо memcmp** — Для сегментов ≥8 байт.
- [ ] **C-8. Query-strip в роутере, не в парсере** — Перенести в stepRequestLine.
- [ ] **C-9. SWAR дублирован** — ByteSearch.findByte и HeaderView.findByte.
- [x] **C-10. ByteBufferAllocator comment** — Исправлен.
- [ ] **C-11. StarlightCore неиспользуемая зависимость NIOCore** — Убрать.
- [ ] **C-12. splitPath двойная аллокация** — Walk UTF-8 напрямую.
- [ ] **C-13. findFirstOf2/findFirstOf dead code** — internal или удалить.

---

## Блок D — API / Clean code

- [x] **D-1. start() default = .tcpEcho** — Изменено на .http.
- [x] **D-2. @inlinable на startup-методах** — Убраны.
- [x] **D-3. @unchecked Sendable на StarlightApp** — Изменено на Sendable.
- [ ] **D-4. Нет deinit cleanup у StarlightServer** — fd и threads утекают без shutdown().
- [ ] **D-5. PaddedAtomicInt64 docs: «three cache lines»** — Реально 264 B = 5 cache lines.
- [ ] **D-6. _value public** — private, forward API.
- [ ] **D-7. parsePattern без валидации** — Пустые param-имена, catch-all.
- [ ] **D-8. Catch-all `*` нереализован** — Удалить из док или реализовать.

---

## Сводная таблица

| Блок | Пунктов | Закрыто |
|---|---|---|
| 0 — Краши/corruption/security | 8 | ✅ 8/8 |
| A — Архитектура | 12 | 7 (A-3, A-9..A-13) |
| B — Логические баги | 12 | 7 (B-1..B-4, B-10, B-12) |
| C — Performance/zero-alloc | 13 | 2 (C-3, C-10) |
| D — API/clean code | 8 | 3 (D-1..D-3) |
| **Итого** | **53** | **27 закрыто, 26 осталось** |
