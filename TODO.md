# Starlight TODO

Актуальный список багов и недочётов после удаления ArenaAllocator.
Идти сверху вниз по приоритетам. Отмечать `[x]` по завершении.
Путь: `file:line` — для быстрого перехода.

---

## Блок 0 — Критичные баги (краши / corruption / security)

- [ ] **0-1. HTTP Request Smuggling: `Transfer-Encoding: chunked` игнорируется** — `HTTP1Parser.swift:61-63,311-331`. `chunkedNotSupported` объявлен в enum ошибок, но никогда не throw-ится. Парсер проверяет только `Content-Length`. Запрос с `Transfer-Encoding: chunked` (без CL) трактуется как bodyless → тело интерпретируется как следующий запрос. RFC 7230 §3.3.3 violation. Реализовать reject или chunked-парсер; при TE+CL — отбрасывать CL.

- [ ] **0-2. Дублирующиеся / конфликтующие `Content-Length` принимаются молча** — `HTTP1Parser.swift:316-325`. Берётся первое значение. RFC 7230 §3.3.2 требует 400 при различии. Считать вхождения, reject при расхождении.

- [ ] **0-3. `parseContentLength` — неполная проверка overflow** — `HTTP1Parser.swift:486-498`. `result = result &* 10 &+ Int(byte - 0x30)` — wrapping arithmetic; ~половина overflow-пространства даёт положительный результат, проходит `if result < 0`. Проверять `> (Int.max - 9) / 10` до умножения.

- [ ] **0-4. `maxRequestBytes` и `maxHeaderCount` объявлены, но не enforced** — `HTTP1Parser.swift:104-110`. DoS-защита — ложь. Добавить проверки в `stepRequestLine`/`stepHeaders`.

- [ ] **0-5. fd-recycling → CQE приписывается чужому соединению** — `IORingExecutorLoop.swift:63-75`. `user_data` пакует только `(fd, op)`, нет connection-id. Ввести монотонный 64-бит connection-id; перед `close` — `IORING_OP_ASYNC_CANCEL`.

- [ ] **0-6. `stopped` и `loopThreadId` — неатомарные data races** — `IORingExecutorLoop.swift:244,238`. Под `StrictMemorySafety` — нарушение. `Atomic<Bool>` / atomic load.

- [ ] **0-7. Соединения не закрываются при shutdown** — `IORingExecutorLoop.swift`. `shutdown()` ставит `stopped = true`, но никто не итерирует `connections` для close. Все fd утекают → EMFILE. Добавить `drainConnections()`.

- [ ] **0-8. NIO backend: `eventLoopGroup` никогда не shutdown-ится** — `Server.swift:79,202`. `shutdown()` закрывает listener channels, но не вызывает `eventLoopGroup.shutdownGracefully()`. NIO thread pool остаётся жить.

---

## Блок A — Архитектурные недочёты

- [ ] **A-1. «Radix-trie router» не существует — O(N) linear scan** — `Router.swift:405-419`, `Package.swift:5-8`. Либо доставить trie, либо убрать «trie» из Package/ROADMAP/комментариев.

- [ ] **A-2. DSL с result-builder отсутствует** — `App.swift` (57 строк), `Package.swift:87`. Package.swift обещает "result-builder DSL". Нет `@resultBuilder`, нет декларативного route API.

- [ ] **A-3. `Router.freeze()` — data race за `@unchecked Sendable`** — `Router.swift:286-304`, вызовы из `HTTP1Codec.swift:119` и `Router.swift:360`. Мутация без синхронизации. `Atomic<Bool>` + `compareExchange`; убрать `freeze()` из codec и `handle()` (уже вызывается из `Server.start()`).

- [ ] **A-4. HTTP-версия валидируется, но выбрасывается** — `HTTP1Parser.swift:248`. Не сохраняется в RequestContext. Следствия: нет keep-alive default для 1.1, нет `Host` enforcement, нет `Expect: 100-continue`, status line всегда `HTTP/1.1`.

- [ ] **A-5. Нет валидации field-name / field-value** — `HTTP1Parser.swift:335-340`. Только наличие `:`. Валидировать token-charset имени (§3.2.6), non-empty, reject CTL в value (§3.2.4). Валидация path-target (§5.3).

- [ ] **A-6. Нет 405/Allow, нет HEAD→GET, нет percent-decoding params** — `Router.swift:362-369` (404 вместо 405), `:217-219` (HEAD), `:456-466` (параметры сырые `%20`). RFC 7231 §6.5.5, §4.1.2.

- [ ] **A-7. Конфликтующие/дублирующие маршруты не детектируются** — `Router.swift:246-263`. Добавить детект структурных коллизий на `add()`.

- [ ] **A-8. Несогласованная нормализация слешей → cache poisoning / ACL bypass** — `Router.swift:448,471-472`. Внутренние `//` коллапсируют безгранично, trailing — один раз. Единая policy: normalize в парсере или reject `//`.

- [ ] **A-9. `ConnectionActor` создаётся на каждое соединение — heap allocation** — `IORingExecutorLoop.swift:446`. 100K соединений = 100K actor allocations. Actor не содержит state. Использовать `Task(executor:)` напрямую.

- [ ] **A-10. `Task {}` без executor binding — initial hop на global pool** — `IORingExecutorLoop.swift:448-450`. Unstructured Task стартует на global pool, затем hops на loop executor. Должно быть `Task(executor: cachedExecutor)`.

- [ ] **A-11. `composeOne` композитит middleware в `routes` (никогда не используется)** — `Router.swift:295-304`. `match()` использует только `staticRoutes`/`dynamicRoutes`. Утроенная работа. Удалить композицию в `routes`; `routeCount = staticRoutes.count + dynamicRoutes.count`.

- [ ] **A-12. `CLinuxExt.h` без `extern "C"` guard** — `CLinuxExt/include/CLinuxExt.h`. C++ consumer не слинкуется.

- [ ] **A-13. `LinuxSocket.swift` — IPv4-only, `inet_pton` без проверки результата** — `LinuxSocket.swift:60-64`. Возвращает 0 при невалидном адресе, но результат игнорируется. IPv6 не поддерживается. `port` truncated до `UInt16` без проверки.

---

## Блок B — Логические баги

- [ ] **B-1. Аккумулятор никогда не освобождает потреблённые байты → memory leak на keep-alive** — `HTTP1Codec.swift:319`. `moveReaderIndex(forwardBy: consumed)` двигает reader, но storage не компактируется. `discardReadBytes()` никогда не вызывается. На keep-alive connection с тысячами запросов storage растёт бесконечно.

- [ ] **B-2. `reset()` не чистит `responseBuffer`** — `RequestContext.swift:130-142`. Stale-байты от предыдущего запроса. При ошибке пути → 500 с stale body.

- [ ] **B-3. `connectionCount -= 1` без underflow protection** — `IORingExecutorLoop.swift:610`. Декремент только если `removeValue != nil`.

- [ ] **B-4. CQE iteration: ошибки молча игнорируются** — `IORingExecutorLoop.swift:343-345`. `catch { }` — потерянные CQE → висящие continuation'ы.

- [ ] **B-5. `HTTPMethod.other` routable → wildcard-method route** — `HTTPMethod.swift:28`, `Router.swift:246`. Маршрут `.other` матчит все неизвестные методы. Запретить `add(.other, ...)`.

- [ ] **B-6. Raw method bytes потеряны** — `HTTPMethod.swift:16-17`. `.other` не хранит raw bytes. `init(span:)` (документирован) не существует. WebDAV методы теряются.

- [ ] **B-7. `HTTPStatus.Hashable` включает `reasonPhrase`** — `HTTPStatus.swift:11-19`. `200 "OK"` ≠ `200 "Ok"` как Dictionary key. `Hashable` только по `code`.

- [ ] **B-8. Status code не валидируется [100, 599]** — `HTTPStatus.swift:15-19`. `HTTPStatus(0)` или `HTTPStatus(9999)` валидно.

- [ ] **B-9. `writeStatusLine` расходится с `defaultReason`** — `HTTPResponse.swift:179-200` vs `HTTPStatus.swift:26-51`. Две независимые таблицы. 408/409/414/501/504 платят интерполяцию. Единая таблица.

- [ ] **B-10. Middleware short-circuit не зовёт outer middleware `after`** — `Router.swift:114-134`. При chain `[A, B, C]` и short-circuit в B: A.after не вызывается (должен — outer middleware должен видеть response).

- [ ] **B-11. `soReusePort` fallback — magic number** — `Server.swift:253-261`. `#else return NIOBSDSocket.Option(rawValue: 15)` — 15 на других платформах может быть другим socket option.

- [ ] **B-12. `HTTP1Codec.swift:136` — `case .async(let fn)` где `fn` never used** — warning. `fn` извлекается, но не используется (handler уже сохранён в `pendingMatch`).

---

## Блок C — Performance / zero-allocation

- [ ] **C-1. Header copy: memcpy на каждый запрос вместо COW-slice из аккумулятора** — `HTTP1Parser.swift:292-296` (copyBlock → clear + writeBytes). Codec уже делает COW-slice для `path` и `body` — то же самое можно сделать для header block. Eliminate copy entirely.

- [ ] **C-2. `HeaderView.values(for:)` аллоцирует `[String]`** — `HeaderView.swift:139-164`. Callback / `visitValues` API.

- [ ] **C-3. Content-Length lookup материализует String** — `HTTP1Parser.swift:317,486`. `ctx.headers["Content-Length"]` создаёт String из ByteBuffer. `findBytes`-вариант + parse digits = zero alloc.

- [ ] **C-4. `Params()` на каждый candidate route** — `Router.swift:406,414`. Вынести `Params` из цикла, `removeAll(keepingCapacity: true)`.

- [ ] **C-5. `RouteSegment.literal(text:bytes:)` хранит данные дважды** — `Router.swift:42`. `text` не читается на hot path. Только `String` + `.withUTF8`.

- [ ] **C-6. `Route.pattern: String` мёртвое хранилище** — `Router.swift:51`. Удалить или wire-up `CustomStringConvertible`.

- [ ] **C-7. Побайтовое сравнение вместо `memcmp`** — `Router.swift:452-455`. `memcmp` для длинных literal-сегментов (≥8 байт).

- [ ] **C-8. Query-strip в роутере, не в парсере** — `Router.swift:400-403`. Происходит при каждом `match()`. Перенести в `stepRequestLine`; `ctx.path` = path-only, `ctx.query` отдельно.

- [ ] **C-9. SWAR дублирован в `ByteSearch.findByte` и `HeaderView.findByte`** — `ByteSearch.swift:68-111`, `HeaderView.swift:322-355`. Унифицировать.

- [ ] **C-10. `ByteBufferAllocator` comment ложен («class allocation»)** — `HTTPResponse.swift:101-106`. `ByteBufferAllocator` — struct, не class. Исправить коммент.

- [ ] **C-11. `StarlightCore` неиспользуемая зависимость NIOCore** — `Package.swift:48-52`. `PaddedAtomic.swift` не использует NIOCore. Убрать.

- [ ] **C-12. `splitPath` двойная аллокация** — `Router.swift:478-480`. `String.split` → `[Substring]` + `.map(String.init)` → `[String]`. Walk UTF-8 → `RouteSegment` напрямую.

- [ ] **C-13. `findFirstOf2` / `findFirstOf` — dead public code** — `ByteSearch.swift:122-216`. `internal` или удалить.

---

## Блок D — API / Clean code

- [ ] **D-1. `start()` default = `.tcpEcho` — foot-gun** — `App.swift:41`, `Server.swift:91`. Для HTTP-фреймворка default = TCP echo. Должно быть `.http`.

- [ ] **D-2. `@inlinable` на startup-методах `App.swift`** — `App.swift:31,38,53`. Ломает resilience без выгоды. Убрать.

- [ ] **D-3. `@unchecked Sendable` на `StarlightApp` — misleading** — `App.swift:28`. Нет mutable state. Обычный `Sendable`.

- [ ] **D-4. Нет `deinit` cleanup у `StarlightServer`** — `Server.swift:67-144`. Если забыть `shutdown()`, listener fd и threads утекают.

- [ ] **D-5. `PaddedAtomicInt64` документация арифметически неверна** — `PaddedAtomic.swift:43-46`. "three full cache lines" → реально 128+8+128 = 264 B = 5 cache lines.

- [ ] **D-6. `_value` public — утечка абстракции** — `PaddedAtomic.swift:62`. `private`, forward нужного API.

- [ ] **D-7. `parsePattern` без валидации** — `Router.swift:484-494`. Пустые param-имена `/:`, catch-all `*` становится literal. Валидировать.

- [ ] **D-8. Catch-all `*` документирован, но не реализован** — `Router.swift:22`. Удалить из док или реализовать.

---

## Сводная таблица

| Блок | Пунктов | Критичных |
|---|---|---|
| 0 — Краши/corruption/security | 8 | 8 |
| A — Архитектура | 13 | — |
| B — Логические баги | 12 | — |
| C — Performance/zero-alloc | 13 | — |
| D — API/clean code | 8 | — |
| **Итого** | **~54** | **8** |

## Рекомендуемый порядок

1. **0-1..0-4** — parser security (smuggling + DoS)
2. **0-5..0-8** — io_uring / NIO lifecycle (fd leak, races, shutdown)
3. **A-3** — Router freeze race
4. **B-1** — accumulator memory leak
5. **B-10** — middleware short-circuit correctness
6. **C-1** — COW-slice для header block (zero-copy)
7. **A-1 / A-2** — честность про «trie» и DSL
