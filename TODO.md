# Starlight TODO

Список оставшихся задач после архитектурного аудита. Закрытые пункты
перечислены в `bench/results/` (P01–P11) и в истории коммитов.

## Прогресс аудита

| # | Баг / Недочёт | Статус | Коммит |
|---|---------------|--------|--------|
| 1 | Retain cycles в executor loops | ✅ | `4d25052` |
| 2 | Shutdown drain + double-close fd | ✅ | `88b7f31` |
| 3 | Мёртвый код в Content-Length branch | ✅ | `7bd2cd9` |
| 4 | Multi-read precondition на channelId | ✅ | `cf0c723` |
| 5 | Query string уничтожается | ✅ (+ QueryView с UTF-8 + URL-decode) | `ce1b83a` |
| 6 | IORingExecutorLoop против дизайн-документа | ⏸ пропущен | — |
| 7 | Router `@unchecked Sendable` | ✅ (type-state: RouterBuilder + Router) | `fa690c9` |
| 11 | Handler не `throws` | ✅ (→ 500 на uncaught error) | `d30a248` |
| 13 | COW-аллокация в `reset()` | ✅ заодно в #5 | `ce1b83a` |
| 17 | Linear scan для `?` | ✅ заодно в #5 (SWAR) | `ce1b83a` |

**Стоимость по throughput**: ~4% на endpoint `/` (296K → 285K req/s).
Основной вклад — `throws` в handler dispatch (~1%), остальное в пределах
шума.

---

## Оставшиеся задачи (по приоритету)

### 🔴 Высокий приоритет

#### #6. IORingExecutorLoop идёт против своего же дизайн-документа
**Сложность**: ~4h
**Риск**: высокий (затрагивает io_uring accept path).

`Sources/StarlightServer/IORingExecutorLoop.swift:155-179` использует
отдельный accept-thread с блокирующим `poll(2)` + spinlock-очередью для
передачи fd в loop-поток. ROADMAP §10 фиксирует: "POLL_ADD + accept4-drain
— лучше, чем native IORING_OP_ACCEPT". Это реализовано в
`EpollExecutorLoop` через `registerWatch`, но **не** в `IORingExecutorLoop`.

Унифицировать: использовать io_uring POLL_ADD для listener fd, drain'ить
backlog через `accept4` на loop thread (как в epoll backend). Убрать
`acceptThreadMain`, `newConnQueue`, `newConnLock`, `eventLoop.wakeup()`.

#### #8. Дублирование путей кодека (`tryParse` vs `tryParseSync` + `dispatchAsync`)
**Сложность**: ~3h
**Риск**: средний.

NIO backend использует async `tryParse()`. Linux backend'ы используют
sync-fast-path `tryParseSync()` + опционально `dispatchAsync()`. Пути
дублируют логику match+dispatch и уже разошлись в обработке 404. Тесты
покрывают только async path.

Унифицировать: один метод, параметризованный "isSyncAllowed" флагом.
Снизить дублирование, уменьшить риск расхождения.

---

### 🟠 Средний приоритет

#### #9. Два `responseBuffer`'а в одном кодеке
**Сложность**: ~1h
**Риск**: низкий.

`HTTP1Codec.responseBuffer` (512 B) для 400/413/500.
`RequestContext.responseBuffer` (512 B) для 404 в `Router.handle()`.
Итого 1 KB на соединение, из которых один буфер используется в одном месте.

`RequestContext.responseBuffer` documented как reusable, но handler'ы
получают `ctx` как `borrowing` и **не могут** в него писать — мёртвый код.

Удалить `RequestContext.responseBuffer`,统一 с `HTTP1Codec.responseBuffer`.

#### #10. `RequestContext: ~Copyable` — формальность без реальной защиты
**Сложность**: ~2h
**Риск**: средний.

Все поля `RequestContext` Sendable. `~Copyable` только запрещает copy, но
инвариант "не escape из handler" обеспечивается сигнатурой `borrowing`,
а не `~Copyable`. При этом `Router.handle(_ ctx: inout RequestContext)`
мутирует ctx, а handler — нет. Несоответствие.

Либо убрать `~Copyable` (он ничего не даёт), либо пересмотреть ownership
модель (handler → `inout`, тогда `responseBuffer` полезен).

#### #12. `HTTP1Codec: @unchecked Sendable` — должно быть `~Copyable`, owned actor'ом
**Сложность**: ~3h
**Риск**: средний.

Кодек используется строго из одного connection-Task. `final class
@unchecked Sendable` здесь не даёт ничего, кроме heap allocation + ARC.
В Swift 6.2 правильная форма — `~Copyable struct`, owned by
`ConnectionActor`. Это также решает #9.

---

### 🟡 Низкий приоритет / Swift 6.2 идиоматика

#### #14. `IORingEventLoop.wakeup()` без проверки `eventFd >= 0`
**Сложность**: ~15min
**Риск**: нулевой.

`Sources/StarlightIORing/IORingEventLoop.swift:216` — `Glibc.write(eventFd, ...)`
без guard. Если вызван до `setup()` или после deinit (eventFd закрыт) —
поведение undefined.

Добавить `guard eventFd >= 0 else { return }`.

#### #15. Неявное `pthread_self() → UInt` в IORingEventLoop
**Сложность**: ~15min
**Риск**: нулевой.

`IORingEventLoop.swift:103` — `loopThreadId.store(pthread_self(), ...)` —
неявное преобразование. В `PollEventLoop.swift:143` — явное
`UInt(pthread_self())`. Несоответствие.

Привести к единому виду с явным `UInt(...)`.

#### #16. Gate `>= 15` для TE-detection — неправильный threshold
**Сложность**: ~15min
**Риск**: нулевой.

`HTTP1Parser.swift:398` — `if lineContentEnd - lineStart >= 15` — это
длина `Content-Length:` (15 байт), но `Transfer-Encoding:` — 18 байт.
Функция `isTransferEncoding` сама проверяет `>= 18`, так что безобидно,
но gate должен быть `>= 18` или два разных gate'а.

Привести к корректному threshold.

#### #18. `EpollExecutorLoop.run()` теряет channelId listener'а
**Сложность**: ~30min
**Риск**: низкий.

`_ = try eventLoop.registerWatch(...)` — channelId discard'нут, нельзя
отменить регистрацию watch без остановки всего loop'а. Уже не критично
после fixed retain cycle (#1), но всё равно неправильно.

Сохранить channelId, deregister при shutdown.

#### #19. Тесты не покрывают sync-dispatch путь
**Сложность**: ~1h
**Риск**: нулевой.

`HTTP1CodecTests` вызывает только `tryParse()` (async). `tryParseSync()` +
`dispatchAsync()` — путь, по которому идут все Linux-запросы — **не покрыт
ни одним тестом**. Также нет тестов на:
- shutdown с in-flight запросами,
- двойной shutdown,
- превышение `maxConnectionsPerLoop`,
- pipelining через sync-путь.

Добавить покрытие.

---

### 🟢 Swift 6.2 идиоматика (бэклог)

#### #20. `final class @unchecked Sendable` вместо `actor` / `~Copyable`
Встречается в: `StarlightServer`, `ServerStats`, `HTTP1Codec`,
`EpollConnection`, `ExecutorConnection`, `EpollExecutorLoop`,
`IORingExecutorLoop`, `IORingEventLoop`, `PollEventLoop`, `IORingBox`.
Swift 6.2 даёт `~Copyable` + `Synchronization.Atomic` + `nonisolated
nonsending` — но проект этим почти не пользуется.

#### #21. `IORingBox` — обёртка над `~Copyable IORing` в `class` теряет гарантии
Позволяет случайно расшарить `ring` между тредами и обойти SINGLE_ISSUER
guarantee. Лучше — `~Copyable struct` с `borrowing` accessor'ами.

#### #22. `ConnectionActor` / `EpollConnectionActor` — пустые actor'ы без state
Вся работа в `loop.echoLoop` / `loop.httpLoop` — это просто функция loop'а.
Actor используется только для executor-pinning. Само состояние (`codec`,
`fd`, `readBuffer`) лежит в `EpollConnection: @unchecked Sendable`.
Объединить: `actor Connection { let fd; let codec; ... }`.

#### #23. `HTTP1Parser.feed` принимает `UnsafeBufferPointer<UInt8>` — должен `Span<UInt8>` (SE-0447)
Swift 6.2 вводит `Span` / `MutableSpan` именно для borrow-over-ABI-boundary.
Текущий API заставляет codec аллоцировать `UnsafeBufferPointer` из
`ByteBuffer.withUnsafeReadableBytes`. `borrowing Span<UInt8>` был бы
zero-cost и memory-safe.

#### #24. `ByteBuffer` для path/body вместо `~Copyable` view
`ctx.path: ByteBuffer` — это COW-copy аккумулятора. На самом деле нужен
`borrowing` view, который не переживёт аккумулятор. `Span<UInt8>` (или
`~Copyable PathView`) был бы правильнее — никаких hidden COW, никаких
refcount bumps.

---

### 🟣 Feature completeness

#### Catch-middleware для error-handling
**Сложность**: ~1h.

`Middleware.init(catch:)` для конвертации ошибок в custom responses:

```swift
builder.use(Middleware { error, ctx in
    switch error {
    case let e as NotFoundError:
        return HTTPResponse.plaintext("not found", status: .notFound)
    default:
        return HTTPResponse.plaintext("error: \(error)", status: .internalServerError)
    }
})
```

#### `HTTPError` enum / syntactic sugar
**Сложность**: ~30min.

```swift
throw HTTPError.notFound
throw HTTPError.badRequest("missing field 'name'")
```

Реализуется как protocol `HTTPError: Error` с `status` property, поверх
`any Error`.

---

## Замечания по процессу разработки

### Incremental build bug с `@inlinable`

При добавлении полей в `RequestContext` (`~Copyable` struct с
`@inlinable init()`) **обязателен clean build** (`rm -rf .build && swift
build`). SPM не инвалидирует inlined-код в dependent-модулях при изменении
layout'а, что приводит к SIGSEGV в несвязанных тестах. Это ограничение
SPM/Swift 6.2, а не баг в изменении.

Альтернатива: убрать `@inlinable` с `init()` для `~Copyable` structs с
большим количеством полей — компромисс между perf и maintainability.

### Methodology для A/B тестов

- Clean build обоих бинарников перед замером.
- Сохранять в `bench/binaries/starlight-{baseline,fix}`.
- Чередовать baseline/fix между прогонами.
- 30s cooldown между прогонами для термальной стабилизации.
- Минимум 3 раунда, считать среднее.
- Результаты фиксировать в `bench/results/P<номер>_<тема>.md`.
