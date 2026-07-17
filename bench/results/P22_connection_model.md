# P22 — Connection model refactor + TaskExecutor (Tokio-style)

A/B test, 12 threads × 256 conns × 10s, endpoint `/`, 25s cooldown,
interleaved baseline/fix.

|              | run 1    | run 2    | run 3    | AVG     |
|--------------|----------|----------|----------|---------|
| baseline     | 283,871  | 289,208  | 278,905  | 283,994 |
| fix          | 319,807  | 309,844  | 319,513  | 316,388 |
| delta        |          |          |          | **+11.4%** |

**Verdict**: significant throughput improvement. Not a warming
artifact — every round of the fix is faster than every round of the
baseline. The win comes from removing the actor method indirection,
the `EpollConnection` class heap allocation, and the associated ARC
traffic.

## What landed

### Phase A — `TaskExecutor` conformance for event loops

Added `extension PollEventLoop: TaskExecutor` and
`extension IORingEventLoop: TaskExecutor`. This unlocks Swift 6.2's
`Task(executorPreference:)` API (SE-0431, macOS 15+/iOS 18+), which
spawns a Task pinned directly to a custom executor — no actor wrapper
needed.

Previously the only way to pin a Task to a custom executor in Swift
6.2 was via an actor with `nonisolated var unownedExecutor`. That's
why `EpollConnectionActor` existed as an empty singleton whose only
purpose was to route Tasks through to the loop's executor.

Added cached `UnownedTaskExecutor` to both event loops (mirroring the
existing `cachedExecutor` for `UnownedSerialExecutor`) so each Task
spawn reuses the same executor ref instead of allocating a fresh
`UnownedTaskExecutor` struct.

Added `taskExecutorPinning` test in PollEventLoopTests verifying
`Task(executorPreference: loop)` runs successfully.

### Phase B — connection model refactor

Removed:
- `EpollConnection` class (heap-allocated, held codec + readBuffer).
- `ExecutorConnection` class (io_uring variant).
- `EpollConnectionActor` (empty singleton actor for executor pinning).
- `ConnectionActor` (io_uring variant).

The connection model now matches Tokio / Hummingbird / Vapor / Go /
Rust axum: per-connection Task with state owned by the Task frame.

New `setupNewConnection`:

    Task(executorPreference: eventLoop) { [weak self] in
        let readBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { readBuffer.deallocate() }

        if isEchoMode {
            await self?.echoLoop(fd: fd, channelId: channelId,
                                  readBuffer: readBuffer,
                                  readBufferSize: 4096)
        } else {
            let codec = HTTP1Codec(router: router)
            await self?.httpLoop(fd: fd, channelId: channelId,
                                 readBuffer: readBuffer,
                                 readBufferSize: 4096,
                                 codec: codec)
        }
    }

Per-connection state:
- `fd`, `channelId` — captured by value (Cheap: 8 B + 4 B).
- `readBuffer` — allocated in Task, deallocated via `defer` (Rust-like
  `Drop` semantics).
- `codec` — constructed in Task, owned by Task. Phase C will make this
  `~Copyable struct`.

The loop's `connections` dict is slimmed to `[CInt: ConnectionState]`
where `ConnectionState` is a 4-byte struct holding just the channelId
(needed for shutdown cancellation). No more per-connection class
instance.

`echoLoop` / `httpLoop` signatures simplified — they now take
`fd: CInt, channelId: UInt32, readBuffer:, readBufferSize:` and (for
HTTP) `codec:` directly as parameters, instead of the previous
`conn: EpollConnection` parameter that wrapped the same data in a
class.

## What's next

This unlocks Phase C (#12 — codec as `~Copyable struct`) and Phase D
(#9 — remove `RequestContext.responseBuffer`). With the codec now
local to the Task frame, both become straightforward.

Tests: 120/120 passed (119 + 1 new taskExecutorPinning test).
