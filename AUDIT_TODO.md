# Starlight Audit TODO

Полный отчёт аудита фреймворка. ~130 пунктов, из них ~25 критичных.
Идти сверху вниз по приоритетам. Отмечать `[x]` по завершении.

Путь к каждому пункту: `file:line` — для быстрого перехода.

---

## Блок 0 — Критичные баги (краши / corruption / security)

Трекать ПЕРВЫМИ. Без них production-run на Linux нестабилен.

- [ ] **C-1. Неверный ABI `io_uring_cqe` в fallback-структуре** — `CStarlightLinux/include/CStarlightLinux.h:68-72`. Порядок полей перевёрнут: kernel ABI = `user_data@0, res@8, flags@12`, а в коде `res@0, flags@4, user_data@8`. Молчаливая порча на системах без `linux-headers`. Переупорядочить + `_Static_assert(offsetof(...) == 0)`.
- [ ] **C-2. Двойной resume checked-continuation → краш** — `StarlightServer/IOUringExecutorLoop.swift:414-425` (read) и `:452-460` (write). При `ensureSQE()==nil` continuation резюмируется, но остаётся в `readWaiters[fd]`; затем `closeConnection` резюмит повторно → `Fatal error: Swift task already resumed`. Перенести `readWaiters[fd] = cont` внутрь `if let sqe`.
- [ ] **C-3. fd-recycling → атрибуция CQE чужому соединению** — `IOUringExecutorLoop.swift:51-63,493-499`. `user_data` пакует только `(fd, op)`, нет `IORING_OP_ASYNC_CANCEL` перед close. Ввести монотонный 64-битный connection-id.
- [ ] **C-4. `ArenaAllocator.allocateUninitialized(_:count:0)` крашит** — `StarlightCore/Arena/ArenaAllocator.swift:186-197`. `count==0` → `baseAddress!` на nil → trap. Добавить `guard count > 0`. SAFETY-комментарий ложен.
- [ ] **C-5. HTTP request smuggling: `Transfer-Encoding: chunked` игнорируется** — `StarlightHTTP/Parser/HTTP1Parser.swift:61-63,311-331`. `chunkedNotSupported` объявлен, но не throw-ится. Реализовать reject или chunked-парсер; при TE+CL отбрасывать CL (RFC 7230 §3.3.3).
- [ ] **C-6. Дубликаты/конфликтующие `Content-Length` принимаются** — `HTTP1Parser.swift:316-325`. Берётся первое значение; RFC требует 400 при различии. Считать вхождения, reject при расхождении.
- [ ] **C-7. `parseContentLength` — неполная проверка переполнения** — `HTTP1Parser.swift:486-498`. `&*`/`&+` оборачивает; ~половина overflow-пространства даёт положительный результат. Проверять `> (Int.max - digit)/10` до умножения, либо кэп в `maxRequestBytes`.
- [ ] **C-8. `maxRequestBytes` / `maxHeaderCount` НЕ enforced** — `HTTP1Parser.swift:104-110`. DoS-защита — ложь. Добавить проверки в `stepRequestLine`/`stepHeaders`.
- [ ] **C-9. `HeaderView` Copyable + `@unchecked Sendable` с сырым arena-указателем → use-after-free** — `StarlightHTTP/HeaderView.swift:50,53`, `RequestContext.swift:9-34`. Обходит `~Copyable`. Сделать `HeaderView` `~Copyable` (или COW ByteBuffer). То же для `bytes(for:)`.
- [ ] **C-10. Дедлок io_uring-loop на ядрах < 5.13** — `IOUringExecutorLoop.swift:480-489,259`. Multishot poll требует ≥5.13; `submitWakeupPoll` вызывается 1 раз, re-arm отсутствует. Добавить re-arm в `handleWakeup` + проверку `IORING_CQE_F_MORE`.
- [ ] **C-11. `shutdown()` утечка всех fd соединений** — `IOUringExecutorLoop.swift:508-511,265-296`. Никто не итерирует `connections` для close. Клиенты без FIN, дрейф к EMFILE. Добавить `drainConnections()` перед exit.
- [ ] **C-12. COW-порча response-буфера при in-flight SEND (use-after-free)** — `IOUringExecutorLoop.swift:88-109`, `HTTP1Codec.swift:36`. Сырой указатель из `withUnsafeReadableBytes` передаётся ядру за пределы замыкания; переиспользование буфера между запросами детачит COW. Пинить буфер / `isKnownUniquelyReferenced` / удерживать storage до CQE.
- [ ] **C-13. `sl_accept4` EINTR-обработка мертва + busy-loop на EMFILE** — `IOUringExecutorLoop.swift:374-389`, `shim.c:321-323`. `accept4` возвращает -1 (не -EINTR); `sl_accept4` вернуть `-errno`.
- [ ] **C-14. `-EAGAIN` на SEND трактуется как фатал → усечённый ответ** — `IOUringExecutorLoop.swift:462-467`. Различать EAGAIN/EPIPE; на EAGAIN — POLL_ADD POLLOUT + retry.
- [ ] **C-15. `sl_ring_init` error-path: double-close fd** — `CStarlightLinux/shim.c:77-115`. После `close(ring_fd)` не сбрасывать в -1 → `sl_ring_exit` закрывает повторно. Добавить `ring_fd = -1` (или `goto fail` cleanup label).

---

## Блок A — Архитектурные недочёты (high)

- [ ] **A-1. «Radix-trie router» не существует — O(N) linear scan** — `StarlightRouting/Router.swift:405-419`, `Package.swift:67`. Или доставить trie, или убрать «trie» из всей документации/Package/ROADMAP/бенчмарка.
- [ ] **A-2. DSL с result-builder отсутствует** — `Starlight/App.swift` (57 строк), `ROADMAP.md:83-104`, `Package.swift:83`. Реализовать `@resultBuilder RouteBuilder`, `Group`, `GET`/`POST` хелперы; либо убрать обещания.
- [ ] **A-3. `Router.freeze()` — data race за `@unchecked Sendable`** — `Router.swift:286-304`, вызовы из `HTTP1Codec.swift:119` и `Router.swift:360`. Мутация без атомиков. `Atomic<Bool>` + `compareExchange`; убрать `#if DEBUG` precondition (`:189-195`).
- [ ] **A-4. HTTP-версия валидируется, но выбрасывается** — `HTTP1Parser.swift:248`, `RequestContext` без `version`. Добавить поле; реализовать keep-alive default, `Host`-enforcement для 1.1 (§5.4), `Expect: 100-continue` (§6.4.2), правильную версию в status line.
- [ ] **A-5. Нет валидации field-name / field-value** — `HTTP1Parser.swift:335-340`. Только наличие `:`. Валидировать token-charset имени (§3.2.6), non-empty, reject CTL/CR в value кроме HTAB (§3.2.4). Валидация path-target (§5.3).
- [ ] **A-6. Нет 405/Allow, нет HEAD→GET, нет percent-decoding params** — `Router.swift:362-369` (404 вместо 405), `:202-222` (HEAD), `:456-466` (параметры сырые `%20`). RFC 7231 §6.5.5, §4.1.2.
- [ ] **A-7. Конфликтующие/дублирующие маршруты не детектируются** — `Router.swift:246-263`. Добавить детект структурных коллизий на `add()`.
- [ ] **A-8. Несогласованная нормализация слешей → cache poisoning / ACL bypass** — `Router.swift:448,469-472`. Внутренний `//` коллапсирует безгранично, trailing — один раз. Единая policy up-front (normalize в парсере или reject `//`).
- [ ] **A-9. `Task {}` на accept-пути + `lazy var cachedExecutor` — гонка** — `IOUringExecutorLoop.swift:401-407`, `:213-215`. `Task(executor: cachedExecutor)` (Swift 6.0+); инициализировать `cachedExecutor` eagerly в `init`.
- [ ] **A-10. `stopped`/`blocked` неатомарные, TOCTOU** — `IOUringExecutorLoop.swift:208,210`. `Atomic<Bool>`; писать `blocked=true` внутри `jobLock` после re-check `poolJobs.isEmpty`.
- [ ] **A-11. OBS-fold rejected вместо fold** — `HeaderView.swift:262-340`. RFC §3.2.4 deprecates but requires handling. Хотя бы документировать reject.
- [ ] **A-12. `HTTP1Codec` / `StarlightServer` — `@unchecked Sendable` прячет реальные гонки** — `Server.swift:48,123` (`ioUringLoops.append` vs `removeAll()` без lock). Auditor-у непонятно, что защищено.
- [ ] **A-13. NIO backend: event loop group никогда не shutdown-ится** — `Server.swift` (NIO path). In-flight соединения не отменяются.

---

## Блок B — Логические баги (medium)

- [ ] **B-1. `reset()` не чистит `responseBuffer`** — `RequestContext.swift:130-142`. Stale-байты на путях, не пишущих ответ.
- [ ] **B-2. `matchLineRange` требует `nl+2` → пустое value не матчится** — `HeaderView.swift:293`. Должно `>= nl + 1` (легальный `X:`).
- [ ] **B-3. Trailing OWS не удаляется** — `HeaderView.swift:313-318`. `value("Connection", equals:"close")` падает на `"close  "`. Shrink end backwards past SP/HTAB.
- [ ] **B-4. Arena: после `reset()` переиспользуется только `chunks.last`** — `ArenaAllocator.swift:225-284`. Остальные — мёртвый RSS. Truncate `chunks` до одного (или largest) в reset; исправить док-клеймо «reuses the same chunks».
- [ ] **B-5. Arena: non-trivial `T` никогда не `deinitialize`** — `ArenaAllocator.swift:186-215`. ARC/resource leak для class/closure/String-heap. Ограничить trivial-типами / вести список deinit-thunk-ов / задокументировать.
- [ ] **B-6. Arena: checked `*`/`+` trap на больших входах** — `ArenaAllocator.swift:167,273-275`. `&+`/`&*` для pointer-арифметики; guard `nextChunkSize <= maxChunkSize/2` перед удвоением.
- [ ] **B-7. `maxChunkSize` не bounded** — `ArenaAllocator.swift:93-95,152`. Один `allocate(bytes: 1<<30)` аллоцирует 1 GiB chunk. Кап или исправить док.
- [ ] **B-8. `bodyLength` computed property fragile** — `HTTP1Parser.swift:114-115`. `assert(state == .complete)` в debug или хранить явно.
- [ ] **B-9. `chunkedNotSupported` / `unexpectedByte(offset:)` — мёртвый API** — `HTTP1Parser.swift:63,69,186`. Реализовать reject; записывать истинный offset при ошибке.
- [ ] **B-10. `sl_listen` IPv4-only + порт truncится при >65535** — `shim.c:284-317`. Валидировать port ∈ [0,65535]; getaddrinfo для IPv6.
- [ ] **B-11. `sl_pin_to_cpu` UB при `cpu >= CPU_SETSIZE`** — `shim.c:327-332`. `if (cpu < 0 || cpu >= CPU_SETSIZE) return;`.
- [ ] **B-12. CQ overflow никогда не детектится** — `shim.c:236-280`. `cq_off.overflow` не читается → потерянные CQE → висящие continuation. Экспонировать + surface.
- [ ] **B-13. `sl_set_keepalive` игнорирует все 4 setsockopt** — `CStarlightLinux.h:321-327`. Вернуть int/errno.
- [ ] **B-14. `connectionCount -= 1` без underflow protection** — `IOUringExecutorLoop.swift:498`. Декремент только если `removeValue != nil`.
- [ ] **B-15. CQE итерация: `if n == 0 break` игнорирует `n < 0`** — `IOUringExecutorLoop.swift:282-288`. `if n <= 0 break`.
- [ ] **B-16. `sl_accept4` отбрасывает peer address** — `shim.c:321-323`. IP allowlist/rate-limit/logs невозможны. Out-params.
- [ ] **B-17. `HTTPStatus` `Hashable` включает `reasonPhrase`** — `HTTPStatus.swift:11-19`. 200 "OK" ≠ 200 "Ok" как ключ метрик. Исключить reasonPhrase.
- [ ] **B-18. `writeStatusLine` расходится с `defaultReason`** — `HTTPResponse.swift:179-200` vs `HTTPStatus.swift:26-51`. Единая таблица; 408/409/414/501/504 платят интерполяцию.
- [ ] **B-19. Status code не валидируется [100,599]** — `HTTPStatus.swift:15-19`. `precondition` или `init?(code:)`.
- [ ] **B-20. `Params` Sendable но mutable invariants не защищены** — `Params.swift:25`. Снапшот + `removeAll` → stale offsets → `nil`. Привязать к контексту (`~Copyable`).
- [ ] **B-21. `pathString` читает с absolute 0 — зависит от NIO getSlice** — `RequestContext.swift:182-188`. Читать через `path.readerIndex`.
- [ ] **B-22. Middleware short-circuit не зовёт inner `after`** — `Router.swift:114-134`. Документировать явно на `shortCircuit` и `init(before:after:)`.
- [ ] **B-23. `HTTPMethod.other` routable → wildcard-method route** — `Router.swift:246`, `HTTPMethod.swift:28`. Запретить `add(.other, ...)` или хранить raw bytes.
- [ ] **B-24. `.other` теряет raw method bytes** — `HTTPMethod.swift:16-17,28`. Документированный `init(span:)` не существует. WebDAV-методы теряются.

---

## Блок C — Перформанс vs. «zero-allocation» (medium)

- [ ] **C-1p. `HeaderView.values(for:)` аллоцирует `[String]`** — `HeaderView.swift:139-164`. Callback / `visitValues` API.
- [ ] **C-2p. Content-Length lookup материализует String** — `HTTP1Parser.swift:317,486`. `findBytes`-вариант, парсить цифры из arena.
- [ ] **C-3p. `Params()` на каждый кандидат-маршрут** — `Router.swift:406,414`. Вынести `Params` из цикла, `removeAll(keepingCapacity:true)`.
- [ ] **C-4p. `ByteBufferAllocator()` heap-аллоцируется в String-overload `match`** — `Router.swift:428`. `internal` / generic `ContiguousBytes` / reuse `sharedAllocator`.
- [ ] **C-5p. `RouteSegment.literal(text:bytes:)` хранит данные дважды** — `Router.swift:42`. `text` не читается. Только `String`, `.withUTF8` на match.
- [ ] **C-6p. `Route.pattern: String` мёртвое хранилище** — `Router.swift:51`. Удалить или wire-up `CustomStringConvertible`.
- [ ] **C-7p. Middleware композится в `routes` (никогда не читается)** — `Router.swift:295-304`. Утраивает closure-аллокацию. Удалить; `routeCount = staticRoutes.count + dynamicRoutes.count`.
- [ ] **C-8p. Побайтовое сравнение вместо `memcmp`** — `Router.swift:452-455`. `memcmp` для длинных literal-сегментов.
- [ ] **C-9p. Query-strip в роутере, не в парсере** — `Router.swift:400-403`. Перенести в `HTTP1Parser.stepRequestLine`; `ctx.path` = path-only, `ctx.query` отдельно.
- [ ] **C-10p. `PaddedAtomic._value` public — утечка абстракции** — `PaddedAtomic.swift:62`. `private`; forward нужного API.
- [ ] **C-11p. SWAR дублирован в `ByteSearch.findByte` и `HeaderView.findByte`** — `ByteSearch.swift`, `HeaderView.swift:322-355`. Унифицировать.
- [ ] **C-12p. `findFirstOf2`/`findFirstOf` dead public code** — `ByteSearch.swift:122-216`. `internal` или удалить.
- [ ] **C-13p. `ByteBufferAllocator` comment ложен («class allocation»)** — `HTTPResponse.swift:105-106`. Это struct. Исправить коммент.
- [ ] **C-14p. `StarlightCore` неиспользуемая зависимость NIOCore** — `Package.swift:48-52`. Убрать.
- [ ] **C-15p. `splitPath` двойная аллокация `[Substring]`+`[String]`** — `Router.swift:478-480`. Walk UTF-8 → `RouteSegment` напрямую.
- [ ] **C-16p. COW-«no memcpy» overclaim** — `StarlightBenchmark/main.swift:149-165`. `write(2)` копирует в kernel. Уточнить док.

---

## Блок D — API / Clean code (low)

- [ ] **D-1. `App.server` public — leaky abstraction** — `App.swift:29`. `private`/`internal`; passthrough только `start/shutdown/stats`. Или удалить `StarlightApp`.
- [ ] **D-2. `start()` default = `.tcpEcho`** — `App.swift:38-50`. Для HTTP-фреймворка — foot-gun. Default HTTP; echo = benchmark concern.
- [ ] **D-3. `@inlinable` на startup-методах `App.swift`** — `:31,38,53`. Ломает resilience без выгоды. Убрать.
- [ ] **D-4. `@unchecked Sendable` на `StarlightApp` misleading** — `App.swift:28`. Нет mutable state. Обычный `Sendable`.
- [ ] **D-5. Нет `deinit` cleanup у `StarlightApp`/`StarlightServer`** — `App.swift`, `Server.swift`. Listeners leak без `shutdown()`.
- [ ] **D-6. `import NIOCore` неиспользуем в `App.swift`** — `:11`. Убрать.
- [ ] **D-7. `PaddedAtomicInt64` API узок vs. имя** — `PaddedAtomic.swift:52,70-85`. Rename → `PaddedStatsCounter` или расширить API.
- [ ] **D-8. Документация «three full cache lines» арифметически неверна** — `PaddedAtomic.swift:43-46`. 128+8+128=264 B = 5 cache lines. Исправить.
- [ ] **D-9. `_leading`/`_trailing` internal, могут быть private** — `PaddedAtomic.swift:58,64`.
- [ ] **D-10. Нет `subtract`/`decrement` у `PaddedAtomicInt64`** — `PaddedAtomic.swift:77-85`. Асимметрия с `add`/`increment`.
- [ ] **D-11. `var chunk` должно быть `let`** — `ArenaAllocator.swift:157`. Live compiler warning.
- [ ] **D-12. `bumpAllocate` двойная индексация массива** — `ArenaAllocator.swift:270,279`. Писать через локальный `chunk.usedBytes`.
- [ ] **D-13. Пустой `@inlinable deinit`** — `ArenaAllocator.swift:246-251`. Убрать `@inlinable` или тело.
- [ ] **D-14. `RouteSegment`/`matchBytes` `@usableFromInline` без выгоды** — `Router.swift:36-45,437-444`. `@inlinable` или `internal`.
- [ ] **D-15. `composeOne` force-unwrap `wrapSync!`** — `Router.swift:324`. `guard let`.
- [ ] **D-16. `parsePattern` без валидации** — `Router.swift:484-494`. `users/:id` без `/`, пустые param-имена, `/files/*` literal вместо catch-all. Валидировать.
- [ ] **D-17. Catch-all `*` документирован, но не реализован** — `Router.swift:22`. Реализовать или удалить из док.
- [ ] **D-18. `bodyLength`/`count` hot-path foot-gun** — `HeaderView.swift:169-184` (count O(blockLen)). Кэш или удалить.

---

## Блок E — C shim (medium/low)

- [ ] **E-1. Дубликат декларации `sl_accept4`** — `CStarlightLinux.h:263,329-330`. Удалить.
- [ ] **E-2. Нет `extern "C"`** — `CStarlightLinux.h:19-20`. C++ consumer не слинкуется.
- [ ] **E-3. `__NR_io_uring_*` могут конфликтовать с `<sys/syscall.h>`** — `CStarlightLinux.h:126-128`. `#ifndef` guard; комментарий про «x86_64» ложен (uniform cross-arch).
- [ ] **E-4. `sl_get_sqe` не пишет `sq_array` — полагается на identity-map из init** — `shim.c:168-191`. Документировать инвариант или писать per-call (как liburing).
- [ ] **E-5. Нет `IORING_SETUP_*` флагов** — `shim.c:47-55`. `SINGLE_ISSUER`/`DEFER_TASKRUN` для thread-per-core. Probe `params.features`.
- [ ] **E-6. `io_uring_register` объявлен, не используется** — `CStarlightLinux.h:128`. `REGISTER_BUFFERS` + `READ_FIXED`/`WRITE_FIXED` — главный io_uring win.
- [ ] **E-7. `sl_io_uring_enter` игнорирует `sigset`** — `shim.c:33-37`. EINTR на SIGTERM.
- [ ] **E-8. `sl_submit` игнорирует partial-submit** — `shim.c:227-232`. `ret < to_submit` → retry или `SUBMIT_ALL`.
- [ ] **E-9. `MAP_POPULATE` лишний на ring mmap** — `shim.c:75,89,105`. Лишняя page-fault latency.
- [ ] **E-10. Нет `<stddef.h>` для `size_t`** — `CStarlightLinux.h`. Self-contained header.
- [ ] **E-11. `sl_prep_recv`/`send`/`poll_add` не `memset` SQE** — `CStarlightLinux.h:265-295`. Асимметрия с `sl_prep_accept`. Добавить memset.
- [ ] **E-12. `sl_wait_cqe` возвращает `-EAGAIN` пост-enter** — `shim.c:255-270`. Лучше `-EINTR`.
- [ ] **E-13. `sl_ring_exit` не защищён от `ring_fd == 0`** — `shim.c:151-164`. `sl_ring_init_zero` или init `ring_fd = -1`.
- [ ] **E-14. Нет `const` на `cqe_out`** — `CStarlightLinux.h:220,227`. `const struct io_uring_cqe **` + `sl_cqe_data(const ...)`.
- [ ] **E-15. `_Static_assert` на offsetof отсутствует** — после fallback block.

---

## Блок F — Тесты (critical для «эталона»)

- [ ] **F-1. Fallback-путь CStarlightLinux — 0 тестов** — `Tests/CStarlightLinuxTests/`. Именно так C-1 прошёл. Отдельная TU + offsetof-тесты.
- [ ] **F-2. `alignmentMustBePowerOfTwo` — no-op (`#expect(true)`)** — `ArenaAllocatorTests.swift:77-91`. Fork+exec trap-тест или переименовать+`Issue.record`.
- [ ] **F-3. `exponentialGrowth` не проверяет размеры чанков** — `ArenaAllocatorTests.swift:108-132`. Только `chunkCount >= 5`. Экспонировать `chunkSizes()` и assert точно.
- [ ] **F-4. `pipeliningTwoRequests` — одинаковый ответ, не проверяет `/second`** — `HTTP1CodecTests.swift:155-170`. Handler echo `ctx.pathString`.
- [ ] **F-5. `handleReturns404` не проверяет статус** — `RouterTests.swift:239-250`. В комменте признано. Assert `404` в status line.
- [ ] **F-6. `Box<T> @unchecked Sendable` — data race в async-тестах** — `RouterTests.swift:22-25,269-330`. `OSAllocatedUnfairLock`/`Atomic<T>` (Swift 6.2).
- [ ] **F-7. Нет тестов SWAR-примитивов (`findByte`/`findFirstOf2`)** — `ByteSearch.swift`. Property-based: random bytes, все позиции, длины 0..32.
- [ ] **F-8. Нет тестов `maxHeaderCount` / `maxRequestBytes`** — `HTTP1ParserTests.swift`. 101 хедер / value >64KiB / request-line >8KiB → reject.
- [ ] **F-9. Нет теста chunked-rejection** — `HTTP1ParserTests.swift`. TE: chunked → `chunkedNotSupported`.
- [ ] **F-10. Нет тестов `HeaderView.bytes(for:)` / `value(_:equals:)`** — `HeaderViewTests.swift`.
- [ ] **F-11. Нет тестов EINTR/EAGAIN на `sl_wait_cqe`** — SIGALRM + `alarm(1)` → assert `-EINTR`.
- [ ] **F-12. Нет тестов SQ/CQ overflow** — заполнить CQ без `sl_cqe_seen` → assert `-EOVERFLOW` (после E-12).
- [ ] **F-13. Нет тестов hot-path socket-функций** — `sl_accept4`, `sl_set_keepalive`, `sl_pin_to_cpu`. Socketpair + getsockopt + sched_getaffinity.
- [ ] **F-14. Нет end-to-end теста `IOUringExecutorLoop` / `StarlightServer`** — bind + connect + request → response.
- [ ] **F-15. Хардкод портов 18080/18081 → flaky CI** — `CStarlightLinuxTests.swift:141,150`. Port 0 + `getsockname`.
- [ ] **F-16. `IORING_OP_NOP.rawValue` ломает fallback-компиляцию** — `CStarlightLinuxTests.swift:62,93,128`. `numericCast(IORING_OP_NOP)` или wrapper-enum.
- [ ] **F-17. Тесты роутера читают body из `headerBuffer` — implementation-coupled** — `RouterTests.swift:353`, `HTTP1CodecTests.swift:208`. Публичный `HTTPResponse.bodyString`.
- [ ] **F-18. `validContentLengthBody` mis-titled** — `HTTP1ParserTests.swift:179-197`. Не проверяет содержимое `ctx.body`. Assert `"hello"`.
- [ ] **F-19. Нет property-based / fuzzing** — parser/router/arena — идеальные кандидаты.

---

## Блок G — Бенчмарк (critical для credibility)

- [ ] **G-1. Бенчмарк ничего не измеряет** — `StarlightBenchmark/main.swift:264-276`. Кумулятивные счётчики, без req/s, latency p50/p95/p99, warmup, steady-state. Реализовать или переименовать в `StarlightServer` (load target).
- [ ] **G-2. Apples-to-oranges с конкурентами** — `ROADMAP.md:30-38`. Pre-serialized cached buffer vs default-alloc конкурентов. Опубликовать harness; две моды (framework-default vs zero-alloc ceiling).
- [ ] **G-3. Handler игнорирует запрос** — `main.swift:143-147` (`_ = ctx`). Эхо path/method → parser provably on path.
- [ ] **G-4. Stats-thread шумит измерение** — `main.swift:264-276`. Unpinned, `usleep(100µs)`-loop (50 syscalls/interval), кумулятивный вывод. Pin вне event-loop ядер, `clock_nanosleep` absolute, per-interval deltas+rates.
- [ ] **G-5. Stats-thread никогда не останавливается** — `main.swift:264-276`. `Atomic<Bool>` stop-flag + SIGINT handler.
- [ ] **G-6. `-h` = `--host`, не `--help`** — `main.swift:84,94`. `-h/--help`; `-H` для host.
- [ ] **G-7. Нет `--opt=value`; missing value silent** — `main.swift:74-104`. Support `=`; hard error на missing value.
- [ ] **G-8. Invalid `--mode` крашит через precondition** — `main.swift:279-293`, `Server.swift:68`. Валидировать в `parseArgs`, `exit(2)`.
- [ ] **G-9. `signal(SIGPIPE, SIG_IGN)` слишком поздно** — `main.swift:233-236`. Поставить первым в `main`.
- [ ] **G-10. `/users/:id` — единственный router-бенчмарк (худший случай)** — `main.swift:216-221`, `ROADMAP.md:21-25`. Отдельные wrk-таргеты: `/health`, `/`, `/users/42`. Пред-сериализованный buffer для `/async`.
- [ ] **G-11. Cargo-cult `let` rebinding** — `main.swift:202-207`. No-op; ByteBuffer и так Sendable. Убрать.
- [ ] **G-12. Hard-coded `Content-Length: 14` без валидации** — `main.swift:155-164,180-200`. Derive из `body.utf8.count` + precondition.
- [ ] **G-13. `backendName = "io_uring"` asserted, не detected** — `main.swift:238-242`, `ROADMAP.md:284-291`. `--backend nio|io_uring|auto`; `StarlightServer` report выбранного.
- [ ] **G-14. Нет readiness signal** — `main.swift:255-293`. Split bind/accept; print «listening».
- [ ] **G-15. Нет final summary** — `main.swift:287-293`. `do/catch` + totals + elapsed.
- [ ] **G-16. Stale phase numbers** — `main.swift:5-6,108,246`. Один label или убрать.
- [ ] **G-17. `out()` аллоцирует Array+Data per line** — `main.swift:48-60`. `String.withUTF8` + `write(STDOUT_FILENO)`.
- [ ] **G-18. Banner «= CPU cores» ложен при `-l`** — `main.swift:250-251`. Conditional annotation.
- [ ] **G-19. `StarlightApp` инстанциируется только ради `.server`** — `main.swift:233-234`. Доказательство что umbrella не используется (см. D-1).

---

## Сводная таблица

| Блок | Пунктов | Критичных |
|---|---|---|
| 0 — Краши/corruption/security | 15 | 15 |
| A — Архитектура | 13 | — |
| B — Логические баги | 24 | — |
| C — Перформанс/zero-alloc | 16 | — |
| D — API/clean code | 18 | — |
| E — C shim | 15 | — |
| F — Тесты | 19 | — |
| G — Бенчмарк | 19 | — |
| **Итого** | **~139** | **~15** |

---

## Рекомендуемый порядок

1. **Блок 0 целиком** — production Linux-run без него невозможен (C-1..C-15).
2. **A-3, A-4, A-5** — синхронизация Router + HTTP-RFC-семантика.
3. **A-1 или документация** — честность про «trie».
4. **A-2 или документация** — честность про DSL.
5. **C-9** — query в парсер; тянет за собой правильный `ctx.path`.
6. **Блок F параллельно с фиксы** — каждый баг покрывать тестом.
7. **Блок G** — перед любыми новыми публикациями перф-заявок.
