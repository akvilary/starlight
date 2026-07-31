# todo.md — путь к production-ready

## Рабочий процесс (договорён)

Для **каждого** пункта ниже:

1. **Предложить решение** — я перепроверяю сам; если есть архитектурные изъяны или ошибки в логике → итерируем заново. Готовое решение отдаю только когда уверен, что оно production-уровня.
2. **Согласовать с вами** — ничего не реализую без вашего ОК.
3. **Реализовать.**
4. **Замер** — `swift build -c release` + `wrk -t12 -c100 -d3s http://localhost:8080/` (3 прогона, медиана). Порог регресса: **> 5% падения** → разбираемся до коммита.
5. **Коммит** — только если регресса нет. В сообщении пишу новую цифру req/s.

Команда замера: `bash /tmp/opencode/bench.sh` (старт сервера → 3×wrk → стоп).

---

## Baseline (замер старта работы)

| Прогон | req/s |
|---|---|
| 1 | 305 457 |
| 2 | 297 467 |
| 3 | 287 723 |
| **Медиана** | **297 467** |

Замер: 31.07.2026, release, loopback, AMD 5600H (12 потоков), wrk `-t12 -c100 -d3s`.
Прежний baseline в AGENTS.md был ~260K — текущее состояние уже выше.

---

## Phase 1 — Критическая корректность / DoS (блокируют production)

> Без этих пунктов сервер нельзя выставлять в интернет — падает под нечестным клиентом.

- [x] **C2. Асинхронная запись ответа через event-loop.**
  Сейчас `driveConnection` пишет синхронными `writeAll`/`writevHeaderBody`/`writeRaw` (`Worker.swift:438,480,843`) с блокирующим `poll(POLLOUT,5s)` при EAGAIN на треде reactor'а. Один медленный клиент морознит весь event-loop. `eventLoop.write`/`TcpStream` существуют, но не используются (мёртвый код). **Самый большой пункт.** Затронет encode/stream-путь.
  **Готово.** Loop = readiness-реактор (`awaitWritable`), драйвер делает оптимистический `write(2)`/`writev` + `await awaitWritable` на EAGAIN. Hot path (writev) неизменен. Регресс ~1,2% (чередованный A/B).

- [ ] **C1. Read-timeout (timerfd в PollEventLoop).**
  `readTimeout` хранится (`H1Conn.swift:135`), но `readWithTimeout()` (`:787`) его не применяет → Slowloris DoS. Нужен per-channel таймер (timerfd) в `PollEventLoop`, вооружаемый вместе с read-interest.

- [ ] **C4. Shutdown busy-loop.**
  `initiateShutdown()` (`Worker.swift:220`) только ставит флаг — listener fd остаётся в epoll (level-triggered) → при непустом backlog 100% CPU. Дерегистрировать/закрывать listener fd при shutdown.

- [ ] **C3. `forceShutdown` обязан вызываться всегда.**
  Сейчас только из таймера (`serve.swift:184`). При естественном дрейне loop'и не останавливаются → утечка тредов / процесс не завершается. Безусловный `forceShutdown` для всех воркеров после дрейна.

- [ ] **C5. `serve()` readiness-таймаут.**
  `serve.swift:154` — ожидание `WorkerStash.count() < loopCount` без таймаута. Падение bind у одного воркера → вечный вис. Таймаут + явная ошибка.

- [ ] **C6. Единый default `onShutdown`.**
  `Starlight.swift:47` (umbrella) блокирует навсегдо и не ставит signal-handlers, тогда как `StarlightServer.serve` (`serve.swift:67`) ставит. Унифицировать: umbrella делегирует с тем же дефолтом.

- [ ] **C7. Единая система лимитов тела + корректные коды ошибок.**
  Экстракторы ловят только `BodyError.limitExceeded`, а `H1Conn` кидает `H1ConnError.requestTooLarge` → ловится в `driveConnection` как **500** вместо 413. `DefaultBodyLimit.read` = `Int.max` без layer (axum даёт 2 MB по умолчанию). Связать `maxBodyBytes` с `DefaultBodyLimit`, вернуть 413.

---

## Phase 2 — Архитектура и логика

- [ ] **A8. Полное срезание hop-by-hop.**
  `H1Conn.swift:523` срезает только известное множество, но не заголовки из списка `Connection:` (RFC 9110 §7.6.1). Утечка custom hop-by-hop в хендлер.

- [ ] **A2. Типизированные хендлеры для любых сочетаний экстракторов.**
  `HandlerService2..6` требуют последний аргумент `FromRequest` (тело) → `(State, Query, Path) -> R` не выразить. Привести к акcum-модели axum (parameter packs / generic per-arity variants «все parts»).

- [ ] **L2. `writeErrorAndClose` передаёт метод запроса.**
  `Worker.swift:418` — `encodeHead` без `requestMethod` → тело на 500 для HEAD. Протянуть метод.

- [ ] **L1. `Form`-декодер без JSON-конверсии.**
  `Form.swift:77,93` — `coerce` ломает числоподобные строковые поля. Свой urlencoded-декодер поверх `StringKeyedDecoder` (как в `Query`).

- [ ] **L4. IPv6 peer address.**
  `Worker.swift:532` — IPv4-only (`sockaddr_in`). IPv6 → «unknown»/мусор. `getpeername` с `sockaddr_storage` + ветвление семейства.

- [ ] **A4. `TimeoutLayer` без TaskGroup.**
  `Timeout.swift:54` плодит 2 Task на запрос — запрещено AGENTS/H1Conn-комментарием. Перевести на timerfd (после C1).

- [ ] **A3. Radix-trie роутер.**
  `Router.swift:417` — линейный scan. Перенести на O(длина пути) trie (аналог `matchit`).

---

## Phase 3 — Production-фичи

- [ ] **TLS** (BoringSSL/s2n): handshake на loop, SNI, cert reload.
- [ ] **HTTP/2**: HPACK, flow control, мультиплексирование, stream state machine.
- [ ] **Обсервабилити**: метрики, structured logging, tracing-хуки.

---

## Phase 4 — Очистка мёртвого кода / перф

- [ ] **D1.** Удалить мёртвые `TcpStream`/`TcpListener.accept` (воркер использует `sl_accept4` напрямую).
- [ ] **D2.** Убрать дубль `PaddedAtomic.swift` (идентичен в `StarlightCore` и `pulsar`).
- [ ] **D3.** Мёртвое в `http-codec`: `HTTPCodecBody`, `ServerTransaction`, `AsyncTimer`.
- [ ] **L10.** `recoverOrphanedContinuations` не освобождает `readBuffer` каналов (`PollEventLoop.swift:483`).
- [ ] **L3.** Эмитить `Date`-заголовок (`emitDateHeader` — мёртвый конфиг, `Encoder.swift:49`).
- [ ] **D6.** Кешировать `JSONEncoder`/`JSONDecoder` (`Json.swift:55,69`).
- [ ] **D8.** `TCP_NODELAY` в `sl_bind_listener` (`helper.c`).
- [ ] **D5.** Заменить magic `0x004` на `POLLOUT` (`Worker.swift:459`) — после C2.
- [ ] **D7.** `maybeCompact` → ring buffer (`H1Conn.swift:824`).
- [ ] **D9.** `RateLimiter` — самоэвикция.
- [ ] **D11.** Превышение `maxConnectionsPerWorker` → 503 вместо молчаливого close.
- [ ] **A1.** Убрать зависимость `StarlightServer → StarlightExtractors` (`Package.swift:115`).
- [ ] **A5/A6.** `PollEventLoop` `@unchecked` — синхронизировать `onWakeup`; swap буферов в `drainJobs`.

---

## Журнал замеров

| Дата | Пункт | req/s (медиана) | Δ к baseline | Коммит |
|---|---|---|---|---|
| 31.07.2026 | baseline | 297 467 | — | (старт) |
| 31.07.2026 | C2 (async writes) | ~293 900 (чередованный A/B: −1,2%) | −1,2% | C2 |
