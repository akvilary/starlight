# Starlight TODO — путь к Swift 6.2 reference

Полный архив ревью: ~30 critical, ~70 high, ~50 medium, ~30 low.
Ниже — существенное по фазам. Каждая фаза = mergeable PR.

---

## Meta-insights (читать перед началом любой фазы)

### Почему вообще возникли эти баги

«Копировали axum 1 в 1» — иллюзия. Скопировали **структуру** (сигнатуры, имена
типов, разбиение по файлам), но не **семантику** (edge cases, invariants).
Сравнение по LOC:

| Слой | axum+hyper+http | Starlight |
|---|---|---|
| http crate (+ httparse) | ~8 000 | ~1 000 |
| hyper H1 | ~15 000 | ~1 500 |
| axum core | ~10 000 | ~1 800 |
| tower-http middleware | ~8 000 | ~1 500 |
| matchit router | ~1 500 | 0 (linear scan) |
| **Итого** | **~42 000** | **~5 800** |

14% объёма при 100% видимой поверхности API. Happy path работает (бенчмарк
294K req/s на `GET /` через loopback это и есть happy path). Любой edge case
ломается. Чтобы реально стать «эталоном», нужно не «починить пункты TODO», а
**дописать недостающие 80% audits/edge cases**. TODO — это карта, не территория.

### Категории багов (полезно понимать перед фиксом)

1. **Rust→Swift semantic mismatches** (A1, A2, A9, A22, A24, C12, C13).
   Код выглядит правильно, потому что синтаксис похож. Семантика — другая.
   Перед фиксом **прочитать документацию Swift-аналога**, не Rust-оригинала.
2. **Cargo-cult: скопировали форму без invariant** (A5, A6, A7, A8, B1, B2).
   Перед фиксом **смотреть axum-оригинал**, понимать «почему так», потом
   переносить семантику, не сигнатуру.
3. **Не перенесённая infrastructure** (B8, C8, C17, C20, D5).
   В axum это работает потому что есть слой ниже (hyper drain'ит, RouteId
   аллоцируется). У нас этот слой отсутствует. Перед фиксом **искать
   соответствующий axum/hyper файл**, не придумывать заново.
4. **Security-аудит отсутствует** (A12, A15, A17, A18, A25, A26).
   axum/tower-http пережили циклы CVE → fix → audit. Мы скопировали **первую
   версию без истории патчей**. Перед фиксом **искать связанные CVE у tower-http
   и hyper**, смотреть, что они делают.
5. **Мёртвый код как permanent state** (A28, C20, D5).
   TODO-комментарии стали состоянием. Каждый такой пункт — либо дописать, либо
   удалить. Полу-меры плодят новый мёртвый код.

### Зависимости между фиксами (делать в порядке)

```
A2 (shutdown hang)        ─── не зависит ───► можно делать первым
A9 (PollEventLoop race)   ─── не зависит ───► можно делать первым
A11 (sigaction)           ─── не зависит ───► можно делать первым
A22 (SWAR endian)         ─── не зависит ───► можно делать первым
A4 (collect early check)  ─── не зависит ───► но тестируется с A3

A3 (DefaultBodyLimit) ────► A4 (collect early check) — связанный тест
A1 (Timeout)          ────► A2 (drain timeout) — та же Swift-ошибка с TaskGroup

A19 (parseHex + total cap) ───► A3 (DefaultBodyLimit) — оба про body cap

B1 (убрать assoc. State) ───► B2 (withState через extensions)
                        ───► B3 (удалить MethodRouter.state, Fn phantom)
                        ───► B5 (Handler conformance)
                        ───► B4 (HandlerService1Body)

C4 (slowloris timeout)  ───► требует рабочий withTimeout (см. A2)
C8 (ServerTransaction wire) ───► C17, C18, C19, C20 — все связаны с keepAlive

D1 (sort by specificity) ───► D6 (Dictionary static routes) — оба про routing
D5 (удалить RouteId)      ───► независимо, но проверь что BoxService docstring
                                про "HashMap<RouteId, …>" тоже правится

A20 (HEAD/204/304 no body) ───► требует знать request method в Encoder →
                                связано с C9 (HTTP/1.0 status line) →
                                оба требуют thread'ить request metadata в encode
```

### Тест-стратегия: IntegrationClient — ПЕРВЫМ

`TestClient` (`Sources/StarlightServer/TestClient.swift`) зовёт
`service.call(request)` напрямую, минуя codec. Это значит:
- ~80% найденных багов (codec, smuggling, trailers, EOF, partial reads,
  write-path, keepAlive) **не ловятся тестами**.
- Любой фикс в codec может регрессить без заметного эффекта на TestClient.

**Перед началом Фазы C** (или даже параллельно с A) — добавить
`IntegrationClient` (D20): real TCP socket → send raw HTTP bytes →
parse raw HTTP bytes. Туда же —- fuzzer для smuggling-векторов
(список ниже в «Тесты которые надо добавить»).

Альтернатива — клонировать `hyper-tests` и `axum-tests` (Rust) и
перенести по одному тесту. Это самый быстрый путь к «эталону».

### Swift 6.2 idioms cheat sheet (использовать при фиксах)

| Что | Неправильно | Правильно (Swift 6.2) |
|---|---|---|
| Race между task и timer | `withTaskGroup { … group.next() … }` | `withCheckedContinuation` + 2 unstructured `Task`s + `withTaskCancellationHandler` |
| Type-erased service dispatch | `@Sendable (Request) -> Response` | `@Sendable (sending Request) -> Response` (ownership transfer, no copy) |
| Shared mutable state | `@unchecked Sendable var x` | `Mutex<T>` (from `Synchronization`) или `Atomic<T>` (from `Synchronization`) |
| Per-thread affinity | "документировать что loop-only" | `nonisolated func … { precondition(pthreadEqual(...) ) }` |
| AsyncSequence type erasure | `@unchecked Sendable any AsyncSequence` | `any AsyncSequence<…> & Sendable where Self.AsyncIterator: Sendable` |
| COW-тип пересекает actor | `struct Foo: @unchecked Sendable { var storage: […] }` | Либо `Mutex`, либо `~Copyable`+`consuming`, либо регион-isolated |
| Signal handling | `signal(SIGINT, …)` + `Task.sleep` poll | `sigaction`+`SA_RESTART`+mask, либо `signalfd` на event loop |
| Body / ownership transfer | copy в闭 late | `consuming Body` + `borrowing` для read-only extractors |
| Path normalization | substring `..` | `realpath(3)` или `openat(2)` walk без FOLLOW |
| Hex/int parse from bytes | `Int(String(decoding: bytes))` | byte-walk с overflow check через `&*` + `&+` и проверкой |

### Reference: какие upstream-файлы смотреть при фиксе

> URL'ы для справки. Если что-то не открывается — гуглить по пути файла
> в соответствующем GitHub репозитории.

**hyper** (https://github.com/hyperium/hyper):
- `hyper/src/proto/h1/decode.rs` — chunked TE, trailers, request target forms
- `hyper/src/proto/h1/encode.rs` — HEAD/204/304, hop-by-hop stripping
- `hyper/src/proto/h1/conn.rs` — read/write timeouts, 100-continue
- `hyper/src/proto/h1/dispatch.rs` — handler error → 500, drain contract
- `hyper/src/proto/h1/io.rs` — `maxBufferSize`, slow read defense

**axum** (https://github.com/tokio-rs/axum):
- `axum/src/routing/mod.rs` — route merging, conflict detection, fallback
- `axum/src/routing/method.rs` — MethodRouter fallback, HEAD/OPTIONS handling
- `axum/src/routing/path_router.rs` — matchit integration, nested fallbacks
- `axum-core/src/extract/from_request.rs` — `S` generic on method (not assoc type)
- `axum-core/src/handler/mod.rs` — macro-generated arity, body-last rule
- `axum/src/middleware/from_fn.rs` — Next.run ownership contract

**tower-http** (https://github.com/tower-rs/tower-http):
- `src/cors.rs` — Vary: Origin, preflight detection, allow-list matching
- `src/services/serve_dir.rs` — `PathBuf::strip_prefix` + canonicalize
- `src/set_header/mod.rs` — Vary append vs insert semantics
- `src/limit/mod.rs` — body limit wire-up
- `src/compression/*` — `async-compression` integration, deflateBound

**tower** (https://github.com/tower-rs/tower):
- `tower/src/util/map_request.rs` — `consuming`-equivalent patterns
- `tower/src/util/box_clone.rs` — type-erased service patterns

**matchit** (https://github.com/ibraheemdev/matchit):
- `src/router.rs` — radix tree, specificity rules
- `src/tree/node.rs` — priority-based child ordering

### Reference: известные CVE и audit'ы, которые нужно перенести

Перед фиксом соответствующих пунктов **обязательно** прогуляться по
upstream-истории. Это экономит недели:

- **CORS Vary: Origin** — tower-http PR #128, CVE-2018-style cache poisoning
- **Request smuggling** — hyper audit 2019 (CL/TE, bare LF, TE substring)
  описан в Bishop-Fox / James Kettle research; hyper test suite покрывает
- **ServeDir traversal** — tower-http commit history `serve_dir.rs`,
  ~5 ревизийsecurity fixes
- **Path matching edge cases** — axum/matchit issues: trailing slash,
  empty segments, param-vs-wildcard precedence
- **Compression Vary** — CVE-class, фиксили почти все HTTP frameworks

### Частые ловушки при портировании Rust→Swift

Запомнить эти паттерны, не повторять:

1. **`tokio::select!` отменяет проигравшего.** В Swift `withTaskGroup` ждёт
   всех. Для race'а — unstructured Tasks + continuation.
2. **`Pin<&mut Self>` = mutable state across `poll`.** Swift `enum` immutable
   по умолчанию. Для stateful body — class или `~Copyable struct`.
3. **Rust trait with `&move self` (очень редко) — consuming.** В Swift
   `consuming` параметр ≠ mutating, не путать.
4. **`async-compression`/`serde_json`/`httparse` — audited dependencies.**
   Их Swift-эквиваленты часто самописные, без audit'а. Любой ручной
   парсер = кандидат на smuggling.
5. **Endianness.** Rust-кодеры явно пишут `to_le/from_le`. Swift-порты
   забывают. SWAR всегда требует `#if _endian(big)`.
6. **`http::Extensions` internally `RwLock`.** Sendable ≠ thread-safe.
   Любой Swift-аналог с mutable Dictionary под `@unchecked Sendable` — гонка.
7. **axum использует macros для генерации arity 0-16.** Swift не имеет
   эквивалента; ручной код становится maintenance burden после arity-4.
   План: SwiftSyntax generator ИЛИ wait для variadic pack ergonomics.
8. **`tower::Service::poll_ready` для backpressure.** Мы выкинули
   (см. `StarlightTower/Service.swift` docstring). Любой middleware,
   которому нужен capacity reservation (buffer, load shed, rate limit
   с token bucket) — не имеет хука. Возможно, придётся вернуть.

### Что НЕ ДЕЛАТЬ при фиксе

- **Не добавлять `@unchecked Sendable` чтобы заткнуть compiler.** Это
  маскировка бага. Если компилятор ругается на Sendable — значит есть
  гонка, её надо фиксить (Mutex/Atomic/region isolation), не annotate.
- **Не использовать `try!` / `as!` на данных из сети.** Любой panic на
  malformed input = DoS через crash.
- **Не плодить мёртвые typealiases и protocol conformances «на будущее».**
  Каждый мёртвый элемент сегодня — debugging-фактор завтра.
- **Не чинить middleware-баги без теста через реальный codec.** TestClient
  их не поймает.
- **Не копировать Rust-код построчно.** Компилируется ≠ работает. Каждый
  портированный метод — гуглить Swift-семантику асинхронного аналога.
- **Не коммитить без benchmark'а** (см. AGENTS.md, 5% threshold).

### Что ДЕЛАТЬ при фиксе (чек-лист на каждый пункт)

1. Прочитать **соответствующий upstream-файл** (см. Reference выше).
2. Найти **edge cases в upstream-тестах** — перенести 3-5 тестов.
3. Написать **failing test first** для каждого фикса.
4. Проверить, что фикс **не ломает** существующие тесты (`swift test`).
5. Запустить `swift build -c release` + benchmark 3 раза (AGENTS.md).
6. В коммите упомянуть номер пункта (A1, B2, …) и upstream-источник.

---

## Фаза A — Critical correctness (блокирует v0.1)

### A1. TimeoutLayer не таймаит и глушит ошибки
- **Файл:** `Sources/StarlightMiddleware/Timeout.swift:42-57`
- **Баги:** `withTaskGroup` ждёт все child tasks (cancelAll кооперативный,
  не прерывает); `try?` коллапсирует любой Error → nil → 504.
- **Фикс:** Переписать на unstructured Task + race через continuation;
  различать handler-error от timeout'а.

### A2. Graceful shutdown hang'ает
- **Файл:** `Sources/StarlightServer/serve.swift:232-245`, `Worker.swift:225-230`
- **Баг:** `withTimeout` использует `withTaskGroup`, чей closure ждёт все
  child tasks. Parked continuation в `waitForDrain` не уважает cancellation.
  30s `drainTimeout` — мёртвый код, `forceShutdown` недостижим.
- **Фикс:** `withTaskCancellationHandler` внутри `waitForDrain`, resume на cancel.

### A3. DefaultBodyLimit не enforced
- **Файл:** `Json.swift:44`, `Form.swift:55`, `Bytes.swift:42`, `FromRequest.swift:187`
- **Баг:** Все body-extractor'ы зовут `collect()` с `maxBytes: .max`.
  `DefaultBodyLimit` layer существует, но никто не читает.
- **Фикс:** В каждом extractor'е `DefaultBodyLimit.read(from:)` → `collect(maxBytes:)`,
  мапить `BodyError.limitExceeded` в 413.

### A4. Body.collect проверяет лимит после append
- **Файл:** `http/Sources/HTTP/Body.swift:211-217`
- **Баг:** Chunk сначала append'ится (аллоцируется), потом проверяется.
- **Фикс:** `if result.count + chunk.count > maxBytes` ДО append.

### A5. Routes не мержатся для одного path
- **Файл:** `Sources/StarlightRouting/Router.swift:73-88`
- **Баг:** `.get("/x", h1).post("/x", h2)` → POST никогда не вызовет h2.
  `call()` возвращает на первом совпадении.
- **Фикс:** Мержить MethodRouter для того же path, или fatalError на дубликат.

### A6. Path-параметры не percent-decode'ятся
- **Файл:** `Sources/StarlightRouting/PathMatcher.swift:120-125`
- **Баг:** Функция задокументирована как percent-decode, реализация — UTF-8
  decode. `/users/hello%20world` → `"hello%20world"`.
- **Фикс:** Реальный `%XX` decoder.

### A7. PathParams.decodeNil всегда false
- **Файл:** `Sources/StarlightCore/PathParams.swift:134`
- **Баг:** Optional<T> поля в `Path<T>` всегда пытаются декодировать wrapped
  value → keyNotFound для отсутствующих параметров.
- **Фикс:** `return !contains(key)`.

### A8. Query<T> не декодирует скаляры
- **Файл:** `Sources/StarlightExtractors/Query.swift:33-56`
- **Баг:** `[String:String]` round-trip через JSONSerialization+JSONDecoder.
  JSONDecoder не коэрцит String→Int. `Query<{id:Int}>` всегда 400 для `?id=42`.
  Также rejects при отсутствующем query string.
- **Фикс:** Переиспользовать `PathKeyedDecoder` из PathParams.swift; не
  падать на пустом query (пусть decoder обрабатывает empty dict).

### A9. PollEventLoop lazy executor cache — data race
- **Файл:** `Sources/StarlightPoll/PollEventLoop.swift:122-141`
- **Баг:** `@unchecked Sendable var` + check-then-set из nonisolated методов.
- **Фикс:** `let` в init, или atomic guard.

### A10. writeAll трактует EAGAIN/EINTR как fatal; accept4 fold'ит errno
- **Файл:** `Sources/StarlightServer/Worker.swift:142-149, 371-389, 327-347`
- **Баг:** При EAGAIN/EINTR write-ответ молча обрезается. Любой errno в
  accept4 silently останавливает accept-loop.
- **Фикс:** errno-propagation в `sl_accept4`/`write(2)`; retry на EINTR,
  poll на EAGAIN.

### A11. signal() вместо sigaction()
- **Файл:** `Sources/StarlightServer/Signal.swift:34-39`
- **Баг:** Нет SA_RESTART, нет signal mask. Любой syscall на worker thread
  при shutdown получает EINTR. 50ms poll вместо signalfd.
- **Фикс:** `sigaction` + SA_RESTART; unblock mask; опционально signalfd.

### A12. ServeDir path traversal
- **Файл:** `Sources/StarlightServer/ServeDir.swift:91-100`
- **Баг:** Substring `..` на сыром URL. Обходит: `%2e%2e`, `..%2F`,
  double-encoding, null bytes, symlinks.
- **Фикс:** URL-decode → reject NUL → `realpath(3)` → verify prefix.
  Доп: single-read loop, `sendfile(2)` (wrapper уже в helper.c), Range/ETag.

### A13. Compression buffer overflow risk
- **Файл:** `Sources/StarlightMiddleware/Compression.swift:85`
- **Баг:** `inputLen + 64` — zlib требует `inputLen * 1.001 + 64`.
  Silent fallback или возможный heap overflow в C.
- **Фикс:** `deflateBound` или формула выше.

### A14. Compression Vary через insert (cache poisoning)
- **Файл:** `Sources/StarlightMiddleware/Compression.swift:107`
- **Баг:** `insert(.vary, "Accept-Encoding")` затирает существующий Vary.
- **Фикс:** Append-семантика.

### A15. CORS: preflight на любой OPTIONS + нет Vary: Origin
- **Файл:** `Sources/StarlightMiddleware/Cors.swift:72-73, 104-139`
- **Баг:** Каждый OPTIONS трактуется как preflight (нужны Origin+ACRM).
  Vary: Origin никогда не ставится → CORS cache-poisoning (CVE-class).
  Default = `*`. Origin byte-exact без нормализации порта.
- **Фикс:** Preflight только при Origin+ACRM; всегда Vary: Origin;
  preflight consult'ит request; normalize scheme/port.

### A16. RateLimit global fallback
- **Файл:** `Sources/StarlightMiddleware/RateLimit.swift:104-107`
- **Баг:** Default keyExtractor fold'ит в `"global"`, когда ConnectInfo нет.
  Первый клиент блокирует всех.
- **Фикс:** Нет default fallback; требовать явный keyExtractor. Доп:
  self-driven eviction, `Retry-After` от windowDuration.

### A17. Smuggling в H1 codec
- **Файл:** `hyper/Sources/Hyper/Proto/H1/Decoder.swift:251-253, 272-274, 296-304`
- **Баг:** bare CR/LF в header value принимается; TE "chunked" через
  substring (`xchunked` парсится как chunked).
- **Фикс:** Reject bare CR/LF; exact-token TE matching.

### A18. Chunked trailer parsing broken
- **Файл:** `hyper/Sources/Hyper/Proto/H1/Decoder.swift:434-449`
- **Баг:** После `0\r\n` scan для первого CRLF вместо `\r\n\r\n`.
  Pipelined requests десинхронизируются. Partial trailers не бросают
  incomplete.
- **Фикс:** Scan для `\r\n\r\n` (через findCRLFCRLF); throw incomplete
  при partial.

### A19. parseHex trap'ит на 32-bit; нет total body cap
- **Файл:** `hyper/Sources/Hyper/Proto/H1/Decoder.swift:470-485`
- **Баг:** `result * 16 + digit` без overflow check. Только 64KB header
  cap, body via chunked unbounded.
- **Фикс:** Overflow-safe parseHex + отдельный `maxBodyBytes` (default 1-10 MiB).

### A20. HEAD/1xx/204/304 получают body
- **Файл:** `hyper/Sources/Hyper/Proto/H1/Encoder.swift:99-148`
- **Баг:** `encodeHead` выбирает framing по форме body, не по методу/статусу.
- **Фикс:** Передать метод/`isBodyForbidden` флаг; suppress body и auto-CL
  для соответствующих статусов.

### A21. Hop-by-hop headers не strip'ятся
- **Файл:** `Decoder.swift:283`, `Encoder.swift:106-112`
- **Баг:** Connection/Keep-Alive/TE/Trailer/Upgrade/Proxy-Connection leak'ают.
- **Фикс:** Normalisation pass после parse, перед encode.

### A22. SWAR wrong на big-endian
- **Файл:** `hyper/Sources/Hyper/Proto/H1/ByteSearch.swift:65-70`
- **Баг:** `trailingZeroBitCount/8` правильно только на LE.
- **Фикс:** `#if _endian(big)` branch + byteSwapped.

### A23. Extensions: @unchecked Sendable + mutable Dictionary
- **Файл:** `http/Sources/HTTP/Request.swift:72-112`
- **Баг:** Sendable контента не даёт thread-safe мутации Dictionary.
- **Фикс:** Mutex-backed, или COW + freeze-before-cross.

### A24. BodyProtocol.nextFrame бесконечный loop для .buffered
- **Файл:** `http/Sources/HTTP/Body.swift:278-299`
- **Баг:** Всегда возвращает `.data(b)`, никогда `nil`. Контракт нарушен
  для канонического конформера.
- **Фикс:** Либо убрать conformance, либо сделать Body stateful.

### A25. HTTP/1.1 без Host принимается
- **Файл:** `Decoder.swift:228-311`
- **Баг:** Нарушение RFC 9112 §3.2.
- **Фикс:** Reject с 400 если version==.http11 и Host пуст/отсутствует.

### A26. CL+TE оба присутствуют — silent chunked-wins
- **Файл:** `Decoder.swift:313-349`
- **Фикс:** Reject с 400 при конфликте.

### A27. 100-Continue не реализован
- **Файл:** `Decoder.swift:134-159`, `Dispatcher.swift:36-54`
- **Баг:** Клиенты с `Expect: 100-continue` dead-lock'ают.
- **Фикс:** После parse header'ов, до body — написать `HTTP/1.1 100 Continue`.

### A28. H1Dispatcher никогда не feeds decoder; body не пишется
- **Файл:** `hyper/Sources/Hyper/Proto/H1/Dispatcher.swift:72-78, 84-100`
- **Баг:** Production работает только потому, что Worker обходит dispatcher.
- **Фикс:** Зафиксить ИЛИ удалить H1Dispatcher как мёртвый путь.

### Фаза A — Insights и грабли

**A1+A2 — корень один.** Оба бага — недопонимание `withTaskGroup`.
Перед фиксом прочитать:
- https://developer.apple.com/documentation/swift/taskgroup — «wait for all»
- https://developer.apple.com/documentation/swift/withtaskcancellationhandler
- [Reference race pattern](https://github.com/apple/swift-evolution/blob/main/proposals/0431-isolated-anyany-sendable.md)

**Правильный паттерн race'а:**
```swift
return await withCheckedContinuation { cont in
    let timer = Task {
        try? await Task.sleep(for: timeout)
        cont.resume(returning: .timeout)  // resume только если ещё не вызвано
    }
    let handler = Task {
        let r = try? await inner.call(request)
        cont.resume(returning: .result(r))  // guard double-resume через atomic flag
        timer.cancel()
    }
    cont.onTermination = { _ in handler.cancel(); timer.cancel() }
}
```
Double-resume защитить `Mutex<Bool>` или `Atomic<Bool>`. НЕ использовать
`withTaskGroup` — она структурно ждёт всех children.

**A3 — coverage test:** отправить 10 MB JSON при `DefaultBodyLimit.layer(.max(2MB))`.
Должно быть 413 Payload Too Large, не 200 OK + heap bloat. Также проверить,
что Content-Length найден через `Content-Length` даже при lowercase
вариациях (`content-length`). И что 413 response включает `Retry-After`
по желанию — но это позже.

**A6 — %XX decoder.** Не использовать Foundation `URLComponents` (он
нормализует слишком многое, ломая пути). Ручной byte-walk: `%` + 2 hex →
byte; `+` НЕ decode'ится в path (только в query). UTF-8 multi-byte —
не decode'ить individual %XX как chars, собирать bytes и потом
`String(decoding: bytes, as: UTF8.self)`. Test case: `%E2%9C%93` → `✓`.

**A12 — ServeDir.** Главная ловушка: `realpath` resolve'ит symlinks. Если
`root` сам по себе symlink — нужно resolve'ить `root.abspath()` один раз
при init, и сравнивать с resolved target. `openat(2)` walk без `FOLLOW`
per-component — safe alternative, не следит symlink'ам вообще. Выбери один.
**Не** использовать `URL(fileURLWithPath:).path` — Foundation нормализует,
но делает это inconsistent с filesystem. Только POSIX APIs.

**A15 — CORS.** Переносить не глядя на tower-http бесполезно. Минимум:
- `Vary: Origin` всегда (даже при `allow_all_origins`)
- Preflight detection: `method == OPTIONS && headers.contains(origin) && headers.contains(accessControlRequestMethod)` — три условия
- Preflight консультирует `Access-Control-Request-Method` (одобряем только
  если в allowedMethods) и `Access-Control-Request-Headers` (поэлементно)
- Origin matching: parse URL, lowercase scheme+host, drop default port
  (443 для https, 80 для http), потом byte compare
- Default ≠ `*`. Default = deny-all (в axum `CorsLayer::new()` permissive,
  но `.default()` restrictive — мы хотим restrictive)

**A17, A18, A19 — H1 codec smuggling.** Главный insight: **hyper test suite
бесплатный**. В репо hyper Tests/HyperTests есть десятки smuggling cases
(`CL.TE`, `TE.CL`, bare LF, oversized chunk). Клонировать, перенести по
одному. Это покрывает 80% работы по A17-A19+A25-A27+A20.

**A22 — SWAR.** `#if _endian(big)` — это Swift builtin. На x86_64/arm64
компилятор выкинет ветку. Test: синтетический payload, где needle падает
на каждый из 8 байтов SWAR-чанка, плюс выровненный и невыровненный старт.
Перенести тесты из `hyper-tests/parse.rs::swar_*`.

**A23 — Extensions.** Главная ловушка: если делать COW + freeze, то
extension'ы на streaming response **перестанут работать** (response.extensions
мутируется из handler'а, потом читается из codec task'а). Безопасный путь —
`Mutex<[ObjectIdentifier: any Sendable]>` (модуль `Synchronization`).
Perf-цена низкая, потому что contention только при insert'е (handler),
не при read (codec и handler читают параллельно). Альтернатива — per-request
actor, но это ломает `Service.call` nonisolated контракт.

**A28 — H1Dispatcher.** Решение «фиксить или удалить» — рекомендую
**удалить**. Worker.driveConnection — единственный production путь,
дублирование dispatcher'а плодит баги. H1Dispatcher имеет смысл только
если когда-нибудь появится non-Linux backend (io_uring, kqueue), но это
далёкое будущее. Удаление упрощает C17, C18 тоже.

---

## Фаза B — Handler/State model (breaking API change)

### B1. Убрать `associatedtype State` из FromRequestParts/FromRequest
- **Файл:** `Sources/StarlightCore/FromRequest.swift:88-120`
- **Проблема:** Каждый встроенный extractor жестит `typealias State =
  AnySendable`. HandlerServiceN требует `E0.State == S`, поэтому при
  `Router<MyState>` ни один встроенный extractor не проходит bound.
- **Фикс:** Сделать методы generic по `S: Sendable`. Extractor'ы сами
  накладывают constraint на S если нужно.

### B2. withState не доставляет state до handler'ов
- **Файл:** `Sources/StarlightRouting/Router.swift:380-387`
- **Проблема:** Handler'ы уже построены с захваченным placeholder state.
- **Фикс:** Передавать state через Request.extensions; State<S> extractor
  читает оттуда. Insertить в dispatch перед вызовом endpoint.

### B3. Удалить мёртвые поля
- `MethodRouter.state` (`MethodRouter.swift:45`)
- `Fn` phantom parameter во всех `HandlerServiceN` (`HandlerService.swift`)
- `bodyAlreadyConsumed` guard (мёртвый — никто не пишет `parts.body = nil`)

### B4. `HandlerService1Body` для `(_ body: FromRequest) -> Out`
- **Файл:** `Sources/StarlightCore/HandlerService.swift:60-86`
- **Проблема:** Нельзя выразить single-arg handler где arg есть body-consuming
  extractor. Нужно подниматься до arity-2 с dummy FromRequestParts.

### B5. HandlerServiceN conform'ит Handler для N=0..6
- **Файл:** `HandlerService.swift`
- **Проблема:** Только HandlerService0 conform'ит; protocol фактически мёртвый.

### B6. Arity 7-16
- **Файл:** `HandlerService.swift`
- **Подход:** SwiftSyntax/Sourcery generator, либо variadic pack когда
  Swift 6.2 позволит.

### B7. consuming-propagating BoxService
- **Файл:** `Sources/StarlightTower/BoxService.swift:44`
- **Проблема:** Closure берёт Request по borrowing → лишняя copy на каждый
  type-erased dispatch (refcount'ы HeaderMap/Body/Extensions).
- **Фикс:** `@Sendable (consuming Request) async throws -> Response`.

### B8. Body не drain'ится при rejection
- **Файл:** `HandlerService.swift:53-56, 76-86, 105-129, …`
- **Проблема:** Unread request bytes остаются в connection buffer → портят
  следующий pipelined request.
- **Фикс:** Explicit drain contract между handler и codec.

### Фаза B — Insights и грабли

**B1 — главная архитектурная дилемма.** Два варианта:

*Вариант 1: методы generic по S.* `fromRequestParts<S: Sendable>(_ parts:, state: borrowing S)`.
State-less extractor'ы пишут `func fromRequestParts<S: Sendable>(_ parts:, state: borrowing S)`
и игнорируют `state`. `State<MyState>` extractor constraint'ит `S == MyState`
внутри тела метода через cast/guard. **Плюс:** polymorphism работает.
**Минус:** каждая реализация принимает лишний параметр.

*Вариант 2: state через extensions.* `Router.withState(s)` insert'ит
`AppState(s)` в `Request.extensions` в `dispatch`. `State<S>` extractor
читает оттуда. Все остальные extractor'ы остаются state-less (associatedtype
`State = AnySendable` либо вообще убрать). **Плюс:** проще API, не нужен
generic по S. **Минус:** type erasure через extensions, runtime cost.

axum использует **Вариант 1**. Но в Swift Вариант 2 — идиоматичнее
(экстракторы не должны знать про state как концепт). Рекомендую Вариант 2:
он же убирает `B1` и `B2` одновременно, а `MethodRouter.state` удаляется
само собой.

**B3 — удаление Fn phantom.** После удаления протокол `Handler` может
остаться marker'ом без associatedtype'ов. Если оставить его — `HandlerServiceN`
conform'ит без условий. Если не нужен как constraint — **удалить вместе с
HandlerResponse typealias**. Меньше surface area = меньше путаницы.

**B4 — HandlerService1Body.** Не вводить отдельный тип. Вместо этого
убрать constraint `E0: FromRequestParts` с `HandlerService1`, оставить
`E0: FromRequest` (supertrait включает parts-only, если сделать
`FromRequest: FromRequestParts` inheritance). Это автоматически даёт
arity-1-body-handler. Проверить, что `Request: FromRequest` retroactive
conformance в `RawRequest.swift` не конфликтует.

**B6 — arity 7-16.** Сейчас каждый arity — ~30 строк дубликата. До
внедрения codegen'а — **не добавлять новые arity вручную**. Лучше:
добавить `HandlerServiceTuple<Tuple: ExtractableTuple>` через variadic
pack (Swift 5.10+ поддерживает parameter packs, но protocol constraints
ограничены — проверить Swift 6.2 status). Если packs не готовы —
Sourcery/SwiftSyntax generator, который из шаблона emits N структур.

**B7 — consuming BoxService.** Главная ловушка: после смены сигнатуры
closure с `(Request)` на `(consuming Request)` **все call sites внутри
closure должны принимать ownership**. Если код внутри зовёт
`inner.call(request)` где `call(_:)` уже consuming —没问题. Но если есть
ветвление (handler вызывается с одним и тем же request дважды в retry) —
сломается. Audit: найти все `BoxService { request in ... }` и проверить,
что request передаётся ровно один раз по consuming-пути.

**B8 — drain contract.** Главная ловушка: streaming body нельзя
"просто вычитать" — это может занять вечность. Решение из hyper:
- Для known-size (Content-Length): read remaining bytes, выкинуть.
- Для chunked: дочитать до last-chunk.
- Для streaming без framing: **закрыть соединение**. Нельзя продолжать
  keep-alive если body не дочитано.
- Для rejection в handler'е (4xx до чтения body): тот же drain, но
  с лимитом по размеру (например 1MB, иначе close).

Поднять drain в Worker.driveConnection, не в HandlerService — handler
не должен знать про I/O. Контракт: handler возвращает `Response`;
Worker решает drain/close на основе оставшегося body state.

---

## Фаза C — Worker/Codec production-ready

### C1. IPv6 getPeerAddress
- **Файл:** `Worker.swift:446-465`
- **Баг:** Только `sockaddr_in`. IPv6 → buffer overflow или `unknown`.
- **Фикс:** `sockaddr_storage` + `inet_ntop` по `ss_family`.

### C2. Listener FD leak
- **Файл:** `Worker.swift:69`
- **Фикс:** `deinit { close(listenerFd) }`.

### C3. serve() readiness gate не таймаутит
- **Файл:** `serve.swift:94-138`
- **Баг:** При worker bind/init failure serve() hang'ает навсегда.
- **Фикс:** Abort + throw когда stash count не растёт после дедлайна.

### C4. Slowloris: read timeouts
- **Файл:** `Worker.swift:264-351`
- **Фикс:** `withTimeout` вокруг `eventLoop.read`. Header timeout (10s) +
  body timeout (длиннее, с min-byte-rate).

### C5. Убрать Worker actor mailbox contention
- **Файл:** `Worker.swift:186-194, 200-206`
- **Проблема:** Каждое connection close есть actor-hop. На 294K req/s без
  keep-alive это доминирующая cost.
- **Фикс:** `inFlightConns: Atomic<Int>` вне actor.

### C6. writev без [iovec] alloc
- **Файл:** `Worker.swift:396-441`
- **Фикс:** `withUnsafeTemporaryAllocation` или 2-element tuple.

### C7. Reuse ConnectInfo per-connection
- **Файл:** `Worker.swift:301`
- **Проблема:** extensions.insert per-request для данных, константных per-conn.
- **Фикс:** Stash boxed ConnectInfo на ConnState.

### C8. Wire ServerTransaction.shouldKeepAlive
- **Файл:** `hyper/Sources/Hyper/Proto/H1/Server.swift:19-41`
- **Баг:** Определено, но не вызывается из dispatcher/Worker. Handler-set
  Connection: close не закрывает соединение.
- **Фикс:** Re-derive keepAlive после encodeHead из response.

### C9. HTTP/1.0 status line
- **Файл:** `Encoder.swift:186-188`
- **Баг:** Hardcoded `HTTP/1.1`.
- **Фикс:** Thread request version в encodeHead.

### C10. Signalfd вместо poll
- **Файл:** `Signal.swift`
- **Фикс:** Register signalfd на event loop; убрать 50ms Task.sleep poll.

### C11. PollEventLoop.channels nonisolated mutability
- **Файл:** `PollEventLoop.swift:104, 281-288, 309-314`
- **Фикс:** `precondition(loopThreadId == pthread_self())` в mutators, или
  Mutex<…>.

### C12. loopThreadId.store(0) теряет jobs
- **Файл:** `PollEventLoop.swift:160-161`
- **Баг:** После run() exit, enqueue'и падают в poolJobs без wakeup.
- **Фикс:** Не сбрасывать tid, либо enqueue в stopped loop должен fail loudly.

### C13. H1Conn/BufferedIO @unchecked Sendable
- **Файл:** `hyper/Sources/Hyper/Proto/H1/Conn.swift:22`, `IO.swift:25`
- **Фикс:** Transfer ownership through `sending` parameter; drop @unchecked.

### C14. acceptConnection silently drops over cap
- **Файл:** `Worker.swift:151-157`
- **Фикс:** Atomic overflow counter, log, optionally 503.

### C15. Worker.handleAccept ignores EPOLLERR/EPOLLHUP
- **Файл:** `Worker.swift:125-131`
- **Фикс:** Inspect isError/isHangup, alert.

### C16. &-= masking arithmetic
- **Файл:** `Worker.swift:158, 201`
- **Фикс:** Use trapping -=. Double-decrement должен crash'ить, не corrupt.

### C17. Handler errors → no 500 in H1Dispatcher
- **Файл:** `hyper/Sources/Hyper/Proto/H1/Dispatcher.swift:36-54`
- **Фикс:** Wrap handler call в do/catch.

### C18. EOF skips write shutdown
- **Файл:** `Dispatcher.swift:39-40, 52-53`
- **Фикс:** `break` вместо early return, или defer shutdown.

### C19. Empty buffered body gets no CL
- **Файл:** `Encoder.swift:114-125`
- **Фикс:** Нормализовать `Body.buffered([])` → `Body.empty`, или убрать
  `!bytes.isEmpty` из предиката.

### C20. ServerTransaction.shouldKeepAlive dead code
- **Фикс:** Wire up, убрать дублирование в Dispatcher/Worker.

### Фаза C — Insights и грабли

**C1 — IPv6.** Главная ловушка: `SOCK_NONBLOCK | SOCK_INET` слушает
IPv4-only. Чтобы слушать v6 нужно `AF_INET6` + `IPV6_V6ONLY=0` для
dual-stack. В `getPeerAddress` — `sockaddr_storage` (128 байт, вмещает
оба), затем switch на `ss_family`: `AF_INET` → `sockaddr_in` cast,
`AF_INET6` → `sockaddr_in6` cast. **Не** выделять `[CChar]` heap —
использовать stack buffer через `withUnsafeTemporaryAllocation`.

**C2 — Listener FD.** `deinit` в actor'е работает, но **не в фоне** —
он跑oрут на actor executor. Если Worker dealloc'ится во время shutdown'а,
deinit может deadlock'нуть если он сам вызывает actor methods. Решение:
`close(listenerFd)` — синхронный syscall, безопасен в deinit. FD closed
один раз; повторный close вернёт EBADF (silent). Добавить
`assert(listenerFd >= 0)` в начале deinit + set fd = -1 после close.

**C4 — slowloris.** После фикса A2 (working withTimeout) — переиспользовать.
Стратегия: per-connection deadline, refreshed после каждого запроса.
Два отдельных timeout'а:
- **header_timeout** (default 10s): обнулится при каждом новом read в
  header-phase. Если read пустой > 10s → close.
- **body_timeout** (default 30s): аналогично для body-phase. Плюс
  **min_byte_rate** (default 1 KB/s): если скорость ниже → close.
HyperError.headerTimeout/bodyTimeout уже определены — заполнить.

**C5 — Atomic вместо actor hop.** Главная ловушка: `Atomic<Int>` из
`Synchronization` module (Swift 6+). Не использовать `@unchecked Sendable var`
+ ручной CAS через `OSAtomicCompareAndSwap` — deprecated/unsafe. Паттерн:
```swift
public nonisolated let inFlightConns = Atomic(0)
// в driveConnection defer:
worker.inFlightConns.wrappingDecrement(by: 1)
// для drain check:
let remaining = worker.inFlightConns.load(ordering: .acquiring)
```
Drain continuation resume'ится при `load() == 0`. Это требует переделки
`waitForDrain` с actor method на nonisolated method, читающий atomic.
Совместимо с A2 fixed timeout.

**C6 — writev без Array.** Главная ловушка: `withUnsafeTemporaryAllocation`
выделяет stack-быстрий буфер, но **вызывает allocator** на каждый вызов.
Лучше — 2-element tuple:
```swift
var iovs: (iovec, iovec) = (
    iovec(iov_base: UnsafeMutableRawPointer(hPtr), iov_len: hCount),
    iovec(iov_base: UnsafeMutableRawPointer(bPtr), iov_len: bCount)
)
iovs.withMemoryRebound(to: iovec.self, capacity: 2) { p in
    writev(fd, p, 2)
}
```
Но это работает только для 2 iov'ов. Если когда-нибудь захотим 3+
(writev headers + body1 + body2) — `withUnsafeTemporaryAllocation`.

**C8 — ServerTransaction.shouldKeepAlive.** Главная ловушка: после
`encodeHead`.Connection header уже выставлен в response.headers. Нужен
**повторный** derive:
```swift
let requestConn = request.headers.first(for: .connection)
let responseConn = response.headers.first(for: .connection)
let keepAlive = ServerTransaction.shouldKeepAlive(
    version: request.version,
    response: response,
    explicitConnection: responseConn ?? requestConn  // response precedence
)
```
Response-установленный Connection: close — закрывает. Request-установленный
Connection: close — тоже. Default по версии.

**C9 — HTTP/1.0 status line.** Главная ловушка: **HTTP/1.0 client может
не понимать chunked TE**. Если request — HTTP/1.0, response НЕ должен
использовать chunked; либо Content-Length, либо close-delimited. Это
требует проверки в `encodeHead`: для 1.0 + streaming body → close. Для
1.0 + buffered → Content-Length. Если когда-нибудь добавим HTTP/1.0
keep-alive (через Connection: Keep-Active) — отдельная ветка.

**C10 — signalfd.** Главная ловушка: signals **должны быть blocked** в
process mask перед signalfd, иначе они достаются handler'у (или default
disposition). Паттерн:
```c
sigset_t set;
sigemptyset(&set);
sigaddset(&set, SIGINT);
sigaddset(&set, SIGTERM);
pthread_sigmask(SIG_BLOCK, &set, NULL);
int sfd = signalfd(-1, &set, SFD_CLOEXEC | SFD_NONBLOCK);
// register sfd on event loop как обычный fd
```
При read signfd → `signalfd_siginfo` struct → `.ssi_signo` скажет какой.
Это требует C-helper в helper.c. После этого `Signal.swift::poll`-цикл
удаляется.

**C11+C12 — PollEventLoop concurrency.** Главная ловушка: после
`loopThreadId.store(0)` в run() defer — incoming enqueue'и не wake'ают.
Решение: **не сбрасывать** tid. После run() exit, loop мёртв — enqueue
должен fall through к немедленному исполнению (или fatal error в debug).
Или: сделать PollEventLoop ~Copyable с явным lifetime — тогда повторный
enqueue после consume — compile error. Радикальный вариант: `Worker.deinit`
cancel'ирует event loop, и worker никогда не переживёт свой loop.

**C13 — H1Conn/BufferedIO.** Главная ловушка: `@unchecked Sendable` здесь
опасно потому что **handler streaming response пишет в writeBuffer из
one task, а codec reads из another**. Решение: ownership transfer через
`sending` (Swift 6.2):
```swift
public func driveConnection(consuming state: ConnState) async {
    // state owned exclusively этим Task
}
```
Без `@unchecked`. Конечный путь: `Worker.acceptConnection` создаёт
`ConnState` по значению, передаёт через `sending` в Task, Task владеет
исключительно до close. Это совместимо с C5 (atomic counters).

**C17+C18+C19+C20 — все связаны с lifecycle.** Решить как единый PR:
1. catch handler error → write 500 + close (C17)
2. На EOF break вместо return → defer shutdown сработает (C18)
3. Body.buffered([]) нормализовать до .empty при construction (C19)
4. Заменить inline keepAlive calc в Dispatcher/Worker на
   `ServerTransaction.shouldKeepAlive` call (C20)
Все четыре — в `hyper/Dispatcher.swift` + `starlight/Worker.swift`,
общий audit path.

---

## Фаза D — Routing/Performance

### D1. Sort dynamicRoutes по specificity
- **Файл:** `Router.swift:411-416`, `PathMatcher.swift`
- **Баг:** `/:foo/:bar` до `/users/:id` shadow'ит. Registration-order
  dependence.
- **Фикс:** Sort by specificity score (literal-segment count descending,
  then param-before-wildcard). Долгосрочно — radix tree (matchit-style).

### D2. route_layer не оборачивает fallback
- **Файл:** `Router.swift:349-359`
- **Баг:** `route_layer(authMiddleware)` кладёт fallback за auth'ом.

### D3. MethodRouter.fallback работает для стандартных методов
- **Файл:** `MethodRouter.swift:105-119`
- **Баг:** Сейчас fallback fire'ит только для extension methods.

### D4. nest пропагирует inner fallback
- **Файл:** `Router.swift:241-248`
- **Баг:** Silent drop.

### D5. Удалить RouteId (или wire up)
- **Файл:** `Sources/StarlightRouting/RouteId.swift`
- **Баг:** Полностью мёртвый. Docstring в BoxService.swift про HashMap<RouteId, …>
  ложна.

### D6. Static routes → Dictionary
- **Файл:** `Router.swift:404`
- **Баг:** O(n) linear scan даже для static routes.

### D7. 405 Allow header включает HEAD
- **Файл:** `MethodRouter.swift:108-110, 123-134`
- **Баг:** HEAD-via-GET работает, но Allow не упоминает HEAD.

### D8. No-collapse для `//` в path
- **Файл:** `PathMatcher.swift:92, 77`
- **Баг:** `/users//me` матчит `/users/me`.

### D9. JSONDecoder/Encoder как module-level static let
- **Файлы:** `Json.swift:46,60`, `Form.swift:74,131`, `Query.swift:56`
- **Баг:** Per-request alloc.

### D10. Encoder.crlf → static let
- **Файл:** `hyper/Sources/Hyper/Proto/H1/Encoder.swift:227`
- **Баг:** Computed property alloc'ает `[UInt8]` на каждый доступ (~20/ответ).

### D11. ASCII-case-insensitive byte compare для Connection/TE
- **Файлы:** `Dispatcher.swift:109`, `Server.swift:34`, `Worker.swift:473`
- **Баг:** `String(decoding:).lowercased().contains(...)` — substring match,
  alloc'и.

### D12. HeaderMap.insert → single-pass find+replace
- **Файл:** `http/Sources/HTTP/HeaderMap.swift:151-154`

### D13. Trace rename → LoggingLayer
- **Файл:** `Sources/StarlightMiddleware/Trace.swift`
- **Баг:** Имя вводит в заблуждение; нет span/trace-id propagation.
- **Альт:** Добавить request-id, propagate через все 3 hook'а.

### D14. Sse keep-alive + backpressure
- **Файл:** `Sources/StarlightCore/Sse.swift:77-100`
- **Баг:** Соединения умирают за nginx 60s без keep-alive. Нет buffer cap.

### D15. Sse @unchecked Sendable без proof
- **Файл:** `Sse.swift:103-104, 117`
- **Фикс:** `where S: Sendable, S.AsyncIterator: Sendable`.

### D16. Sse Connection: keep-alive invalid для HTTP/2
- **Файл:** `Sse.swift:93`
- **Фикс:** Убрать; connection semantics — ответственность codec'а.

### D17. Redirect.to → 307 вместо 302
- **Файл:** `Sources/StarlightCore/Redirect.swift:39-43`
- **Баг:** Документация вводит в заблуждение; diverges от axum.

### D18. Form encoder не escape'ит &=+%
- **Файл:** `Sources/StarlightExtractors/Form.swift:150-152`
- **Баг:** `urlQueryAllowed` пропускает =, &, +, ;. Round-trip ломается.

### D19. Host extractor trusts X-Forwarded-Host
- **Файл:** `Sources/StarlightCore/Host.swift:42-58`
- **Фикс:** Trusted-proxy gate; RFC 7239 parser для multi-hop и quoted values.

### D20. TestClient не exercises codec
- **Файл:** `Sources/StarlightServer/TestClient.swift`
- **Фикс:** Добавить IntegrationClient через real TCP.

### D21. HandlerServiceN per-dispatch Request reconstruction
- **Файл:** `HandlerService.swift:116-120, 166-170, …`
- **Фикс:** Изменить `FromRequest.fromRequest` на `inout RequestParts`,
  consume `parts.body` напрямую.

### D22. Streaming responses per-chunk flush
- **Файлы:** `Dispatcher.swift:92-98`, `Worker.swift:336-347`
- **Фикс:** Configurable flush policy (N bytes or T µs).

### D23. Method as enum
- **Файл:** `http/Sources/HTTP/Method.swift`
- **Баг:** Struct с static let'ами — нет exhaustive switch.

### D24. EncodedHead leak'ает body-write ответственность
- **Файл:** `Encoder.swift:33-43`
- **Фикс:** Single `encode(response:) -> [UInt8]` или callback API.

### Фаза D — Insights и грабли

**D1 — specificity sort.** Простая эвристика (до radix tree):
```
score(pattern) = (literal_segments_count * 1000) - (param_count * 10) - (has_wildcard ? 1 : 0)
sort dynamicRoutes descending by score
```
Test cases (найти в matchit tests):
- `/:foo` vs `/users` — `/users` выигрывает (статический)
- `/:foo/:bar` vs `/users/:id` —后者 выигрывает (больше static segments)
- `/files/*path` vs `/files/:id` —后者 выигрывает (param beats wildcard)
- `/users/:id` vs `/users/:name` — **одинаковый score**, undefined behavior
  (axum паникует при регистрации; нам тоже нужно panic или warn)

В долгой перспективе — перенос matchit (Rust) на Swift. ~1500 строк,
включая приоритезированный radix tree. Если не переносить — вырастет
O(n) linear scan после ~50 routes.

**D5 — RouteId.** Решение: **удалить**, не wire'ить. RouteId в axum нужен
для:
- metrics по route (count, latency histogram per route)
- `MatchedPath` (но у нас он уже работает через extensions)

Если metrics когда-нибудь понадобятся — добавить RouteId тогда с audit'ом.
Сейчасwire-up = написать allocation site + handler plumbing ради фичи, которой
нет. Не делать. Также убрать docstring в BoxService.swift про «HashMap<RouteId, …>».

**D6 — static routes через Dictionary.** Главная ловушка: trailing slash.
`Dictionary<String, MethodRouter>` с key = pathString. Решить политику
**до реализации**:
- `/users` и `/users/` — один и тот же route? axum: разные.
- При регистрации `/users` матчить `/users/`? axum: нет.

Рекомендую: разные ключи, разные routes. Покрыть тестами с trailing slash.

**D9 — JSONDecoder static.** Главная ловушка: `JSONDecoder`/`JSONEncoder`
**thread-safe на Linux** (Foundation), но **НЕ documented как таковые на
Apple platforms**. Поскольку мы target Linux (Glibc) — безопасно делать
module-level `static let`. Если когда-нибудь захотим macOS — обернуть в
`Mutex<JSONDecoder>` или per-thread cache. Test: параллельно decode 1000
запросов из 100 Tasks, проверить что нет corruption.

**D11 — ASCII case-insensitive byte compare.** Главная ловушка: НЕ
использовать `.lowercased()` — это alloc'ает String. Правильный паттерн:
```swift
@inline(__always)
func asciiEqualsIgnoreCase(_ a: UInt8, _ b: UInt8) -> Bool {
    // OR с 0x20 если в A-Z range — lowercase только ASCII letters
    let aLower = (a >= 0x41 && a <= 0x5A) ? a | 0x20 : a
    let bLower = (b >= 0x41 && b <= 0x5A) ? b | 0x20 : b
    return aLower == bLower
}
```
Connection/TE tokens — comma-separated, trim OWS (0x20, 0x09), потом
byte compare. Перенести в `hyper/Server.swift` как static helper,
использовать во всех 3 местах.

**D13 — Trace rename / rewrite.** Главная ловушка: если переименовать в
`LoggingLayer` — breaking change для пользователей. Предложить:
1. `LoggingLayer` (новый, с request-id propagation через extensions)
2. `TraceLayer` оставить как deprecated typealias на LoggingLayer
3. После v0.2 — удалить

Request-id pattern: insert в `onRequest` через `request.extensions.insert(RequestId(UUID()))`,
read в `onResponse` через closure параметр. Дать пользователям hook
`onRequest: (Method, String, RequestId) -> Void`.

**D14 — Sse keep-alive.** Главная ловушка: если source stream ничего не
производит 60s, мы должны вставить `: keep-alive\n\n`. Реализация через
`AsyncSequence` merge: race между source.next() и timer.sleep() (как A1,
**НЕ через withTaskGroup**). Добавить `SseKeepAlive` struct с configurable
interval (default 15s) и `SseEvent.comment("")` как heartbeat. Test:
source который never produces → через 16s клиент получает heartbeat.

**D15 — Sse @unchecked Sendable.** Главная ловушка: `AsyncThrowingMapSequence`
из standard library — Sendable если base Sendable. Если мы делаем свою
wrapper, constraint должен быть:
```swift
public struct SseStream<S: AsyncSequence>: Sendable
    where S: Sendable, S.AsyncIterator: Sendable, S.Element == SseEvent
```
Оба constraints — `S` и `S.AsyncIterator`. Если опустить — compiler
примет, но runtime будет race.

**D17 — Redirect.to → 307.** Главная ловушка: 302 historically не preserve'ит
method (POST → GET). 307 — preserve'ит. Большинство modern apps хочет 307.
Но **нельзя молча поменять** — сломает существующих пользователей.
Решение:
- Оставить `Redirect.to` → 302 (back-compat)
- Добавить `Redirect.temporary` → 307 (semantic alias)
- Добавить `Redirect.permanent` → 301 (имеется)
- Document в migration guide

Либо breaking change (v0.2), если готовы. В axum `Redirect::to` недавно
поменяли на 307 — это был breaking, но всё равно сделано.

**D18 — Form encoder.** Главная ловушка: Foundation `CharacterSet.urlQueryAllowed`
не делает то, что ожидается. Правильный encoder — ручной:
- Всегда `%`-encode: `&`, `=`, `+`, `%`, `#`, `?`, space (→ `%20`, не `+`)
- В значениях: дополнительно `\`, `"`, `<`, `>` (для HTML safety)
- В ключах: дополнительно `[`, `]`, `:` (если используется bracket notation)
Reference: `serde_urlencoded` Rust source.

**D20 — IntegrationClient.** Главная ловушка: real TCP test требует
**timeout** (тест может hang'уть при codec-баге). Паттерн:
```swift
withTimeout(.seconds(5)) {
    let client = IntegrationClient(host: "127.0.0.1", port: port)
    let response = try await client.send(raw: "GET / HTTP/1.1\r\n\r\n")
    // parse raw bytes, assert
}
```
Запускать server в `Task.detached`, port=0 для OS-assigned port (binding
возвращает реальный port). Test cases: smuggling векторы (A17-A18),
trailers (A18), HEAD без body (A20), 100-continue (A27), pipelined
requests, partial reads (split на любом байте).

**D21 — HandlerService reconstruction.** Главная ловушка: смена сигнатуры
`fromRequest(_:consuming Request, …)` на `fromRequest(_:inout RequestParts,
consuming body: Body, …)` — breaking change для всех custom extractor'ов.
Альтернатива: добавить новый protocol `FromRequestV2` рядом, deprecated
старый, миграция по списку. Но это плодит мёртвый код. Решение для
v0.2: breaking change одним PR.

**D23 — Method as enum.** Главная ловушка: если сделать enum — все switch
statement'ы получат exhaustiveness check. Плюс — compiler safety. Минус —
нельзя расширить без изменения type (нужно `case other(Method)` или
`case custom(String)`). axum/hyper используют enum. Рекомендую enum с
`case custom(raw: [UInt8])` fallback. Breaking change — мигрировать через
deprecation warning.

**D24 — EncodedHead.** Главная ловушка: текущий pattern заставляет каждого
call'ера (Dispatcher, Worker) reimplement'нуть body-write logic. Решение —
push body iteration в Encoder:
```swift
public func encode(
    response: Response,
    into buffer: inout [UInt8],
    writeBody: (inout [UInt8]) async throws -> Void  // called once if buffered/stream
) async throws
```
Или: вернуть `AsyncSequence<[UInt8]>` из encode, let caller iterate.
Первый — проще для back-compat.

---

## Не срочное (low priority backlog)

- `default_` trailing underscore → `.default`
- `HandlerResponse` typealias — удалить
- `StaticString.intoResponse` — 3 alloc'а, свести к 0
- `Substring.intoResponse` — 2 alloc'а
- `Unit` wrapper для `()` handlers — добавить overload
- `Bytes IntoResponse` без Content-Type → `application/octet-stream`
- `Response.bytes` без Content-Type → то же
- `Response.plain` alloc'ает Array из String
- `HeaderMap.==` order-sensitive — документировать
- `HeaderName/Value` — `[UInt8]` per header, нет interning
- `BodyError` — только 2 кейса без payload
- `findCRLF` — удалить (нет call sites)
- `H1Conn.State.readingBody` — удалить (никогда не ставится)
- `chunkedNotSupported` — удалить (реализовано)
- `LoopThreadId` assertion в Worker nonisolated mutators
- `connectInfo` helper dead code (`setConnectInfo` не вызывается из Worker)
- `WorkerStash.shared` singleton — concurrent serve() collides
- `forceShutdown` serial после withTimeout — parallel per-worker
- `accept4` while-true drain без yield — thundering herd
- `installShutdownSignalHandlers` не unblock'ает mask
- `connectChannel` alloc 8KB buffer eagerly
- `recoverOrphanedContinuations` увеличивает overflowEvents всегда
- `ChannelId` UInt32 truncation of UInt64 token
- `processChannelEvent` watch branch — fragility

---

## Тесты которые надо добавить (покрытие gaps)

- Same-path-different-method registration (поймает A5)
- `withState` после handler registration (поймает B2)
- Percent-encoded path params (поймает A6)
- Optional fields в `Path<T>` (поймает A7)
- `Query<{id: Int}>` для `?id=42` (поймает A8)
- Dynamic-vs-dynamic precedence (param vs wildcard)
- Double-slash в path (поймает D8)
- HEAD запрос к GET-only route (Allow header)
- OPTIONS без явного handler
- `MethodRouter.fallback` overriding 405
- `route_layer` не wrapping fallback
- `nest` propagating fallback
- TimeoutLayer: handler throws → не 504 (поймает A1)
- TimeoutLayer: timeout fire'ит ДО завершения handler (поймает A1)
- Drain timeout fire'ит (поймает A2)
- 10 GB body POST при DefaultBodyLimit=2MB (поймает A3, A4)
- ServeDir: `%2e%2e`, null byte, symlink (поймает A12)
- Header value с embedded LF (поймает A17)
- `Transfer-Encoding: xchunked` (поймает A17)
- Chunked body с trailers (поймает A18)
- 32-bit chunk size overflow (поймает A19)
- HEAD response без body (поймает A20)
- HTTP/1.1 без Host → 400 (поймает A25)
- `Expect: 100-continue` (поймает A27)
- IPv6 client connection (поймает C1)
- Slowloris: 1 byte/sec (поймает C4)
- Big-endian byte search (поймает A22)

---

## Сделанные замены (история)

- 2026-07-22: Убран generic `<B>` из Request/Response/RequestParts (3 коммита:
  http 6c3ee2f, hyper 1587b35, starlight b8d33f3). Benchmark: ~294K req/s avg
  (baseline 234K ROADMAP / 260K AGENTS.md — без регресса).
