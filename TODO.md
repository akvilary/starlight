# Starlight TODO

Актуальный список багов и недочётов.
Идти сверху вниз по приоритетам. Отмечать `[x]` по завершении.

---

## Блок 0 — Критичные баги (краши / corruption / security) — ✅ ЗАКРЫТ

- [x] **0-1. HTTP Request Smuggling: `Transfer-Encoding: chunked` игнорируется** — Reject any TE header per RFC 7230 §3.3.3. Per-line detection (zero end-of-headers scans).
- [x] **0-2. Дублирующиеся / конфликтующие `Content-Length` принимаются молча** — Per-line count tracking. Fast path (0-1 CL) via subscript, full `values(for:)` only for >1.
- [x] **0-3. `parseContentLength` — неполная проверка overflow** — Pre-multiply check `> (Int.max - 9) / 10` replaces wrapping `&*`.
- [x] **0-4. `maxRequestBytes` и `maxHeaderCount` не enforced** — Checks in `stepRequestLine` + `stepHeaders`. `headerCount` counter per request.
- [x] **0-5. fd-recycling → CQE приписывается чужому соединению** — Monotonic `connId: UInt32` replaces fd in `user_data`. readWaiters/writeWaiters keyed by connId.
- [x] **0-6. `stopped` и `loopThreadId` — неатомарные data races** — `Atomic<Bool>` + `Atomic<UInt>`.
- [x] **0-7. Соединения не закрываются при shutdown** — `drainConnections()`. `closeConnection` fixed underflow.
- [x] **0-8. NIO backend: `eventLoopGroup` никогда не shutdown-ится** — `syncShutdownGracefully()` in `shutdown()`.

---

## Блок A — Архитектурные недочёты

- [ ] **A-1. Router — O(N) linear scan вместо trie** — `Router.swift`. Либо доставить trie, либо убрать «trie» из всей документации.
- [ ] **A-2. DSL с result-builder отсутствует** — `App.swift`. Нет `@resultBuilder`, нет декларативного route API.
- [x] **A-3. `Router.freeze()` — data race** — `Atomic<Bool>` + `compareExchange`. Убран из hot path codec.
- [ ] **A-5. Нет валидации field-name / field-value** — `HTTP1Parser.swift`. Только наличие `:`. Валидировать token-charset (§3.2.6), reject CTL в value (§3.2.4).
- [ ] **A-6. Нет 405/Allow, нет HEAD→GET, нет percent-decoding params** — `Router.swift`. RFC 7231 §6.5.5, §4.1.2.
- [ ] **A-7. Конфликтующие/дублирующие маршруты не детектируются** — `Router.swift`. Детект коллизий на `add()`.
- [ ] **A-8. Несогласованная нормализация слешей → ACL bypass** — `Router.swift`. Внутренние `//` коллапсируют, trailing — один раз. Единая policy.
- [x] **A-9. ConnectionActor: per-connection → per-loop** — 12 аллокаций вместо 100K. Полное устранение требует `Task(executor:)` (SE-0416, не в Swift 6.2.4).
- [x] **A-10. Task hop — частично исправлен** — Per-loop actor. Initial hop остаётся до `Task(executor:)`.
- [x] **A-11. `composeOne` композитит middleware в `routes`** — Композиция в `routes` убрана из `freeze()`. `routes` array используется только для `routeCount`.
- [ ] **A-12. `CLinuxExt.h` без `extern "C"` guard** — C++ consumer не слинкуется.
- [ ] **A-13. `LinuxSocket.swift` — IPv4-only, `inet_pton` без проверки** — IPv6 не поддерживается.

---

## Блок B — Логические баги

- [x] **B-1. Аккумулятор memory leak на keep-alive** — `discardReadBytes()` в `afterDispatch()` после `ctx.reset()`. In-place compaction, zero COW alloc.
- [ ] **B-2. `reset()` не чистит `responseBuffer`** — `RequestContext.swift`. Stale-байты от предыдущего запроса.
- [x] **B-3. `connectionCount` underflow** — Fixed: декремент только если `removeValue` succeeded (в `closeConnection`).
- [ ] **B-4. CQE iteration: ошибки молча игнорируются** — `IORingExecutorLoop.swift`. `catch { }` — потерянные CQE → висящие continuation.
- [ ] **B-5. `HTTPMethod.other` routable → wildcard-method** — Запретить `add(.other, ...)`.
- [ ] **B-6. Raw method bytes потеряны** — `.other` не хранит raw bytes. WebDAV методы теряются.
- [ ] **B-7. `HTTPStatus.Hashable` включает `reasonPhrase`** — `Hashable` только по `code`.
- [ ] **B-8. Status code не валидируется [100, 599]** — `HTTPStatus(0)` валидно.
- [ ] **B-9. `writeStatusLine` расходится с `defaultReason`** — Две независимые таблицы. Единая таблица.
- [x] **B-10. Middleware short-circuit outer `after`** — Анализ: НЕ баг. Outer `after` вызывается через nested wrapping. Regression test добавлен.
- [ ] **B-11. `soReusePort` fallback — magic number** — `#else return rawValue: 15` на других платформах.
- [x] **B-12. `HTTP1Codec.swift` — unused `fn` binding** — `case .async(let fn)` → `case .async` (fn не использовался).

---

## Блок C — Performance / zero-allocation

- [ ] **C-1. Header copy: memcpy вместо COW-slice** — `copyBlock` → clear + writeBytes. Codec уже делает COW-slice для path/body.
- [ ] **C-2. `HeaderView.values(for:)` аллоцирует `[String]`** — Callback API.
- [x] **C-3. Content-Length lookup материализует String** — Per-line detection: 0 CL → skip, 1 CL → subscript (fast), >1 → values(for:) (rare). Оптимизировано в Block 0.
- [ ] **C-4. `Params()` на каждый candidate route** — Вынести из цикла, `removeAll(keepingCapacity:)`.
- [ ] **C-5. `RouteSegment.literal(text:bytes:)` хранит данные дважды** — `text` не читается на hot path.
- [ ] **C-6. `Route.pattern: String` мёртвое хранилище** — Удалить или wire-up `CustomStringConvertible`.
- [ ] **C-7. Побайтовое сравнение вместо `memcmp`** — Для literal-сегментов ≥8 байт.
- [ ] **C-8. Query-strip в роутере, не в парсере** — Перенести в `stepRequestLine`.
- [ ] **C-9. SWAR дублирован** — `ByteSearch.findByte` и `HeaderView.findByte`. Унифицировать.
- [x] **C-10. `ByteBufferAllocator` comment ложен** — Исправлен: убрано упоминание «class allocation».
- [ ] **C-11. `StarlightCore` неиспользуемая зависимость NIOCore** — Убрать из Package.swift.
- [ ] **C-12. `splitPath` двойная аллокация** — Walk UTF-8 → `RouteSegment` напрямую.
- [ ] **C-13. `findFirstOf2` / `findFirstOf` — dead public code** — `internal` или удалить.

---

## Блок D — API / Clean code

- [x] **D-1. `start()` default = `.tcpEcho`** — Изменено на `.http`.
- [x] **D-2. `@inlinable` на startup-методах** — Убраны из `App.swift`.
- [x] **D-3. `@unchecked Sendable` на `StarlightApp`** — Изменено на `Sendable`.
- [ ] **D-4. Нет `deinit` cleanup у `StarlightServer`** — Listener fd и threads утекают без `shutdown()`.
- [ ] **D-5. `PaddedAtomicInt64` документация: «three cache lines»** — Реально 128+8+128 = 264 B = 5 cache lines.
- [ ] **D-6. `_value` public — утечка абстракции** — `private`, forward API.
- [ ] **D-7. `parsePattern` без валидации** — Пустые param-имена, catch-all `*` как literal.
- [ ] **D-8. Catch-all `*` документирован, но не реализован** — Удалить из док или реализовать.

---

## Сводная таблица

| Блок | Пунктов | Закрыто |
|---|---|---|
| 0 — Краши/corruption/security | 8 | ✅ 8/8 |
| A — Архитектура | 12 | 4 (A-3, A-9, A-10, A-11) |
| B — Логические баги | 12 | 4 (B-1, B-3, B-10, B-12) |
| C — Performance/zero-alloc | 13 | 2 (C-3, C-10) |
| D — API/clean code | 8 | 3 (D-1, D-2, D-3) |
| **Итого** | **53** | **21 закрыто, 32 осталось** |
