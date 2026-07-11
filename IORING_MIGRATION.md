# IORing Migration Plan — Research Notes

## Цель
Перевести StarlightServer с самописного C-шима io_uring на
`SystemPackage.IORing` от Apple (swift-system ≥ 1.8.0 main).

## Что Apple swift-system IORing даёт (Sources/System/IORing/)

### Ring management (готово, Apple-maintained):
- `IORing(queueDepth:flags:)` — `~Copyable` struct с `deinit` (munmap + close)
- SQ/CQ ring management с `Atomic<UInt32>` (правильные `.acquiring`/`.releasing`)
- Feature detection: `IORING_FEAT_SUBMIT_STABLE`, `IORING_FEAT_NODROP`, `SINGLE_MMAP`
- Registered files: `registerFileSlots(count:)` → `RegisteredResources<RegisteredFile>`
- Registered buffers: `registerBuffers(...)` → `RegisteredResources<RegisteredBuffer>`
- EventFD: `registerEventFD(descriptor:)` / `unregisterEventFD()`
- Linked requests: `prepare(linkedRequests: Request...)`
- SetupFlags: `singleSubmissionThread` (SINGLE_ISSUER), `deferRunningTasks` (DEFER_TASKRUN),
  `clampMaxEntries` (CLAMP), `pollSubmissions` (SQPOLL), `continueSubmittingOnError` (SUBMIT_ALL)
- Blocking/async completion consumption: `tryConsumeCompletion()`, `blockingConsumeCompletion(timeout:)`,
  `blockingConsumeCompletions(minimumCount:timeout:consumer:)`
- Typed `throws(Errno)` error handling
- Lifetimes-based safe `Span`/`MutableSpan` access to registered buffers
- Cancel operations: by context, by fd, by fd slot, any

### Доступные операции (RawIORequest.Operation enum):
```
nop=0, readv=1, writev=2, fsync=3, readFixed=4, writeFixed=5,
pollAdd=6, pollRemove=7, syncFileRange=8, sendMessage=9, receiveMessage=10,
asyncCancel=14, link_timeout=15, openAt=18, close=19, filesUpdate=20,
statx=21, read=22, write=23, openAt2=28, unlinkAt=36
```

### Публичный API для запросов (IORing.Request):
```swift
Request.read(socketFd, into: buffer)          // IORING_OP_READ = recv на сокете
Request.write(buffer, into: socketFd)         // IORING_OP_WRITE = send на сокете
Request.read(socketFd, into: registeredBuf)   // READ_FIXED
Request.close(fd)                             // IORING_OP_CLOSE
Request.cancel(.all, matchingContext: tag)    // IORING_OP_ASYNC_CANCEL
```

### Чего НЕТ в публичном API:
- `IORING_OP_ACCEPT` (opcode 13) — пропущен в enum. Обход: pollAdd(listener) + sync accept4()
- `IORING_OP_SEND` (26) / `IORING_OP_RECV` (27) — пропущены. Обход: read/write (эквивалент send/recv flags=0)
- `IORING_OP_CONNECT` (16) — пропущен (не нужно для сервера)
- Socket setup (socket/bind/listen/setsockopt) — нет в IORing, используем Glibc/FileDescriptor

## Ключевое: read/write работают на сокетах
`IORING_OP_READ` (opcode 22) и `IORING_OP_WRITE` (opcode 23) — универсальные.
На сокете эквивалентны recv/send с flags=0.
Ядро не различает файл и сокет на уровне vfs_read/vfs_write.

## Требования
- `#if compiler(>=6.2) && $Lifetimes` — нужен Swift 6.2+ с экспериментальным флагом Lifetimes
- `#if os(Linux)` — только Linux
- swift-system из main ветки (или ≥ 1.8.0 когда зарелиозят)
- На macOS — fallback на NIO (уже работает на ветке nio-only)

## Сетевые операции через IORing public API

| Нужна операция | IORing API | io_uring opcode | Эквивалент |
|---|---|---|---|
| Принять соединение | `pollAdd(listener)` + sync `accept4()` | POLL_ADD=6 + syscall | accept (opcode 13 нет в enum) |
| Читать из сокета | `Request.read(connFd, into: buf)` | READ=22 | **recv** (flags=0) |
| Писать в сокет | `Request.write(buf, into: connFd)` | WRITE=23 | **send** (flags=0) |
| Poll на fd | (есть в Operation enum) | POLL_ADD=6 | poll |
| Закрыть fd | `Request.close(fd)` | CLOSE=19 | close |

Ключевой инсайт: `read`/`write` на socket fd = `recv`/`send` без flags.
Для accept — `pollAdd` listener + sync `accept4` drain (тот же паттерн что сейчас).
`IORING_OP_ACCEPT` (opcode 13) пропущен в enum, но обход через pollAdd работает.

## Что нужно написать (reactor поверх IORing)
1. Event loop на одном потоке: IORing + eventfd wakeup (registerEventFD)
2. Socket setup: socket/bind/listen/SO_REUSEPORT (через Glibc)
3. Accept loop: pollAdd(listener) → accept4 drain (как сейчас)
4. Connection recv: prepare(Request.read(fd, into: buf)) → submit → CQE → cont.resume
5. Connection send: prepare(Request.write(buf, into: fd)) → submit → CQE → cont.resume
6. Per-connection state: readBuffer, sendBuffer, pendingResponse
7. ConnectionActor: `nonisolated unownedExecutor` → SerialExecutor (как IOUringExecutorLoop)
8. CPU pinning: sched_setaffinity (через Glibc)
9. Job queue: для cross-thread enqueue (spinlock + eventfd wakeup, как сейчас)
10. Shutdown: drain connections + close fds

## Что УДАЛЯЕТСЯ из текущего кода
- `Sources/CStarlightLinux/` — весь C-шим (shim.c + header) → ~672 LOC
- `IOUringExecutorLoop.swift` — ring management часть (mmap, atomics, get_sqe, submit, wait_cqe, peek_cqe)
  остаётся только reactor logic
- Зависимость `CStarlightLinux` из Package.swift

## Пункты аудита, которые закроются автоматически
- C-1 (CQE ABI) — нет своего struct, Apple использует kernel header
- C-3 (fd-recycling) — IORing cancel + registered files решают
- C-10 (deadlock <5.13) — wakeup через registerEventFD
- C-11 (shutdown fd leaks) — IORing deinit + наш drain
- C-15 (double-close) — нет своего ring_fd management
- Блок E целиком (C shim issues) — нет C shim
- A-9 (lazy cachedExecutor) — тот же паттерн, но на IORing
- A-10 (stopped/blocked race) — тот же паттерн, но eventfd от Apple

## Текущее состояние веток
- `main` — самописный io_uring (commit af9b866), 15 крит. багов из аудита
- `nio-only` — NIO на всех платформах с actor-pinning (commit 2e1b559), ~50% throughput io_uring
- AUDIT_TODO.md — полный отчёт аудита (на main)

## Бенчмарк-ориентир
- io_uring (main): ~275K req/s (c100, 12-core)
- NIO actor-pinning (nio-only): ~147K req/s (c100, 12-core)
- swift-system IORing: ожидается близко к io_uring (~250-275K), но с Apple-maintained ring
