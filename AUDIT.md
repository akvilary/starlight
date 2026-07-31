# Starlight Production-Readiness Audit

Fresh audit after the axum-mirror refactoring. Every item below was found
by reading the source end-to-end. Severity tiers:

- **P0 — showstopper**: incorrect on the wire, hangs, crashes, or blocks
  every real-world deployment.
- **P1 — correctness/security bug**: wrong behaviour for some class of
  inputs; exploitable or user-visible.
- **P2 — design/API/ergonomics**: works, but hurts users or blocks scale.
- **P3 — performance/cleanup**: works correctly, just slow or messy.

Each item cites `file:line`. Tests: 53 pass, build clean.

---

## P0 — Showstoppers

### P0-1. Request bodies > ~56 KB are rejected (decoder feed cap)
`Sources/StarlightServer/Worker.swift` reads in 8 KB chunks and calls
`decoder.feed(chunk)`. `H1Decoder.feed` enforces
`buffer.count + bytes.count > maxRequestBytes` where
`maxRequestBytes = 64 * 1024` (`http-codec/.../Decoder.swift:147`,
`:107`). The decoder buffers the **entire request (headers + body)**
before returning `.complete`, so any body that does not fit in 64 KB
minus headers throws `requestTooLarge`, the Worker writes a 400 and
closes the connection.

**Verified empirically:** a 100 KB POST returns ECONNRESET.
`DefaultBodyLimit` is 2 MB — unreachable. **Every file upload, every
non-trivial JSON POST is broken.**

Fix: `maxRequestBytes` must limit the *header* block only; the body
must be allowed to grow up to `DefaultBodyLimit`. Either (a) stop
checking `feed()` once headers are parsed, or (b) stream the body
out of the decoder instead of buffering it (the right long-term fix,
matches hyper/axum).

### P0-2. Streaming responses are sent without `Transfer-Encoding`
`H1Encoder.encodeHead` pre-scans `response.headers` and records
`sawTransferEncoding = true` when the user (or `Response.stream`)
sets it (`Encoder.swift:109-115`). It then strips hop-by-hop headers
in the write loop (`Encoder.swift:132-139`), which removes the user's
`Transfer-Encoding`. The auto-framing block then sees
`!sawTransferEncoding == false` and skips adding `chunked`
(`Encoder.swift:142-146`). Net result: a streaming body is written in
chunked framing (`5\r\nhello\r\n0\r\n\r\n`) but **with no
`Transfer-Encoding: chunked` header and no `Content-Length`**. The
client interprets the chunk framing as body bytes.

**The hello-world `/stream` endpoint is broken for any spec-compliant
client.**

Root cause: pre-scan sets `saw*` flags for headers that the same
function later strips. Same bug affects `Connection` (see P0-3).

Fix: do not consult `sawTransferEncoding`/`sawConnection` for hop-by-hop
headers — those will be stripped. Always emit framing headers the
encoder itself owns.

### P0-3. `Connection` header is dropped from responses
Same root cause as P0-2. If the user sets `Connection: close`,
`sawConnection = true` (pre-scan) → encoder skips its own Connection
header → user's Connection is stripped as hop-by-hop → wire has no
Connection header at all. Client/proxy defaults differ from what the
server intended.

`Worker.swift:321` also computes keepAlive from `request.headers.first(for: .connection)`,
but the decoder already stripped hop-by-hop headers from the request
(`Decoder.swift:422`), so this lookup is **always nil** — the keep-alive
decision ignores the client's explicit `Connection: close`.

### P0-4. `serve()` hangs forever if any worker fails to bind
`serve.swift:82-138`. Each worker thread does
`listenerFd = try starlightBindWorkerListener(...)` inside a `do {
} catch { return }` (`serve.swift:93-98`). On bind failure the thread
exits silently. The caller then polls
`while WorkerStash.shared.count() < loopCount` (`serve.swift:136`)
which will **never** reach `loopCount` — `serve()` hangs forever
with no error.

Fix: surface bind failures (shared atomic / result array) and abort
`serve()` with a thrown error.

### P0-5. No read timeout — Slowloris DoS
`Worker.driveConnection` does `await eventLoop.read(...)` with no
timeout (`Worker.swift:274`). A client that opens N connections and
sends one byte per connection holds N Tasks forever, each consuming a
slot in `inFlightConns` (cap 8192/worker). With SO_REUSEPORT and
`loopCount` workers, the attacker needs `8192 * loopCount` sockets to
exhaust the server — trivially achievable.

axum/hyper enforce per-read + per-request timeouts. Starlight has
`TimeoutLayer` (handler-level) but nothing at the connection level.

Fix: wrap every `eventLoop.read` in `withTimeout` (or arm a per-conn
timer via `eventLoop`) + an overall request deadline.

### P0-6. `writeErrorAndClose` never writes the response body
`Worker.swift:380-390`:
```swift
_ = H1Encoder().encodeHead(response, keepAlive: false, into: &writeBuffer)
_ = writeAll(fd: fd, buffer: writeBuffer)
```
`encodeHead` returns `.buffered` (meaning "body is separate") but the
return value is discarded and only `writeBuffer` (the head) is flushed.
Every 400/500 emitted by the Worker is sent with a `Content-Length`
header promising bytes that never arrive. Compare with the main path
which correctly uses `writevHeaderBody` (`Worker.swift:351-356`).

### P0-7. EMFILE/ENFILE accept storm → 100 % CPU
`Worker.handleAccept` treats every `accept4` error other than EINTR as
"drained" and `break`s (`Worker.swift:150-154`). Under fd exhaustion
EMFILE is returned persistently; the listener stays readable, epoll
re-fires immediately, `handleAccept` loops on the same EMFILE forever.
Classic nginx/Apache pathology, well-documented mitigation exists
(accept-mutex, or pause the watch + sleep).

---

## P1 — Correctness / Security Bugs

### P1-1. `getPeerAddress` is IPv4-only; IPv6 breaks RateLimit + ConnectInfo
`Worker.swift:494-513` uses `sockaddr_in` unconditionally. IPv6
connections get `"unknown"`. All IPv6 clients collapse into one
`RateLimitLayer` bucket — one client can starve every IPv6 user, and
the `ConnectInfo` extractor is useless on IPv6 deployments. Use
`sockaddr_storage` + `inet_ntop` keyed off `ss_family`.

### P1-2. `MethodRouter.allowedMethods()` omits HEAD when GET is registered
`MethodRouter.swift:165-176`. `dispatch` serves HEAD from the GET slot
(`head ?? get`, `:152`), but `allowedMethods()` only reports HEAD when
`head != nil`. 405 responses therefore advertise an `Allow` header
that is missing a method the server actually answers. RFC 9110 §15.5.5.

### P1-3. `RateLimiter` is fixed-window, not sliding-window; memory grows unbounded
`RateLimit.swift:19-79`. Comment says "sliding-window" but the
implementation resets every `windowDuration` (fixed window → 2× burst
at the boundary). `evictExpired()` exists (`:72`) but nothing calls
it — the `windows` dictionary grows for the lifetime of the process.

### P1-4. `Form<T>` does not decode Bool or arrays
`Form.swift:92-97`. `coerce` handles only Int/Double/String. A form
field `active=true` stays a String and `JSONDecoder` fails on `Bool`
fields. Repeated keys (`tag=a&tag=b`) overwrite — `[String]` fields
are unsupported. axum's `serde_urlencoded` handles both.

### P1-5. `Query<T>` does not support repeated keys (arrays)
`Query.swift:31-53`. `?id=1&id=2` keeps only the last value. Same
limitation as P1-4.

### P1-6. `Form.intoResponse` produces invalid urlencoded output
`Form.swift:158-160`. Uses `.urlQueryAllowed` which does not escape
`=`, `&`, `+`, `%`. A value like `"b=c"` round-trips as `a=b=c`
(corrupt). Also double-encodes via JSON encode → JSON parse.

### P1-7. `ServeDir` loads the entire file into memory
`ServeDir.swift:244-255`. Allocates `maxFileSize` (default 10 MB) per
request, no streaming. `sl_sendfile` is wrapped in `CLinuxExt/helper.c`
but never called — dead code. Concurrent requests for large files OOM
the process.

### P1-8. `ServeDir` ignores conditional requests
`ServeDir.swift` generates an ETag (`:263-264`) but never checks
`If-None-Match` / `If-Modified-Since`. Every hit re-sends the full
body. No `Range` support either.

### P1-9. `Host` extractor trusts `X-Forwarded-Host`/`Forwarded` unconditionally
`Host.swift:42-61`. No trusted-proxy gate. Any client can spoof the
Host. Behind a reverse proxy this enables host-poisoning of redirects,
cache keys, etc.

### P1-10. No `Date` response header (RFC 9110 §6.6.1 MUST)
`H1Encoder` has `Config.emitDateHeader = true` (`Encoder.swift:49`) but
the field is never read — no Date header is ever written. Origin
servers MUST emit Date.

### P1-11. `H1Decoder` enforces its own `maxBodyBytes` for chunked bodies
`Decoder.swift:135` (`2 MB`) is independent of `DefaultBodyLimit`.
Setting `DefaultBodyLimit.layer(.init(maxBytes: 10*1024*1024))` still
rejects chunked bodies > 2 MB. The two limits must agree.

### P1-12. `Worker.forceShutdown` resumes pending reads with -1 but Tasks may not observe cancellation
`PollEventLoop.recoverOrphanedContinuations` (`PollEventLoop.swift:483-498`)
resumes read continuations with -1. `driveConnection` checks `n <= 0`
and returns (`Worker.swift:275`) — OK. But Tasks blocked in
`router.call(request)` (inside a handler awaiting something) are NOT
cancelled. The drain timeout force-shuts the loop but in-flight
handler Tasks keep running until they naturally complete. They may
write to a closed fd (EBADF → silent). No structured cancellation.

### P1-13. `Redirect.to` returns 302, axum returns 307
`Redirect.swift:41-43`. 302 lets some clients rewrite POST→GET on the
redirected request. axum (and the modern recommendation) is 307
(preserves method). Behavioral divergence from the stated port target.

### P1-14. `Connection`-close on HTTP/1.0 ignored
Consequence of P0-3. The Worker computes keepAlive from the request,
but the Connection header is stripped by the decoder before the Worker
sees it. HTTP/1.0 + `Connection: keep-alive` is ignored (server
closes), and HTTP/1.1 + `Connection: close` is also ignored (server
tries keep-alive, then sees EOF).

### P1-15. Streaming chunk writes are not writev-batched
`Worker.swift:360-370`. Each SSE event = one `writeAll` syscall. Under
high event rate this is a syscall/event. axum/hyper coalesce.

---

## P2 — Design / API / Ergonomics

### P2-1. `HandlerService0-6` is unusable due to the phantom `Fn` parameter
`HandlerService.swift`. Type inference fails at every call site — the
README admits this and routes users through the closure-based API
(`BoxService(handler)`). The typed-extractor path (the whole point of
the axum port) is effectively dead. Either adopt Swift 6.2 parameter
packs to remove the phantom parameter, or commit to the closure path
and drop HandlerService0-6.

### P2-2. `RouteId` is dead code
`RouteId.swift`. Never allocated or consulted. axum uses it for
diagnostics; Starlight's Router doesn't.

### P2-3. `TcpListener` / `TcpStream` classes are unused
`StarlightServer/TcpListener.swift`, `TcpStream.swift`. `serve()` uses
raw fds + CLinuxExt. These ship in the public API but nothing inside
the server uses them.

### P2-4. Test helpers ship in production
`TestClient.swift`, `IntegrationClient.swift`, `IntegrationServer.swift`
are in `Sources/StarlightServer/`. Users who `import Starlight` pull
in `IntegrationClient`, `IntegrationError`, `RawResponse`, etc. Move
to a separate `StarlightTesting` module (axum gates behind a feature).

### P2-5. Router does linear scan over static routes
`Router.swift:417-429`. Comment claims this is the "fast path" but for
apps with >50 static routes it's O(n) per request. axum uses a radix
trie; the minimum viable fix is a `Dictionary<String, MethodRouter>`
for static routes.

### P2-6. Dynamic routes are unordered
`Router.swift:423-429`. Match priority is registration order. axum
sorts by specificity (`/users/me` beats `/users/:id`). Two dynamic
patterns on the same prefix match in an order users can't reason
about.

### P2-7. No TLS / HTTPS
README marks planned. Can't deploy to production internet without a
reverse proxy (which most do, but should be explicit).

### P2-8. No WebSocket
README marks planned. Limits use cases.

### P2-9. No observability hooks
No request counter, latency histogram, error rate. `PaddedAtomicInt64`
exists but isn't wired. No `tracing` equivalent.

### P2-10. `Sse` has no keep-alive heartbeat
`Sse.swift`. Long-lived SSE connections are silently killed by
proxies that enforce an idle timeout (nginx default 60s). axum's SSE
supports periodic `:` comments.

### P2-11. `Sse` / `AsyncThrowingMapSequence` use `@unchecked Sendable`
`Sse.swift:103, 117`. Should propagate Sendable constraints on the
underlying `AsyncSequence`/iterator instead of `@unchecked`.

### P2-12. `Body` enum's `.stream` uses `any AsyncSequence<[UInt8], Error> & Sendable`
Existential AsyncSequence — every `next()` goes through a witness
table. For streaming hot paths this matters. Consider a concrete
struct protocol or typed stream.

### P2-13. Router does not validate route patterns
`Router.route` accepts any string. `""`, `"users"` (no leading `/`),
`"/:"` (empty param name) all parse silently into surprising
behavior. axum panics on invalid patterns.

### P2-14. `PathPattern` only supports `:param` / `*wildcard`
No `{param}` (modern axum) or regex constraints. Minor compatibility.

### P2-15. No `ServiceBuilder` / `.service()` ergonomics for handlers
Layers must be applied via `.layer(Layer { ... })`. axum's
`ServiceBuilder().layer(A).layer(B).service(handler)` is more
ergonomic. `HTTPPrism/ServiceBuilder.swift` exists but isn't surfaced
in the README or Router API.

---

## P3 — Performance / Cleanup

### P3-1. `JSONDecoder()` / `JSONEncoder()` allocated per request
`Json.swift:55,69`, `Form.swift:81,82`. Foundation allocates each
call. Make module-level `static let`.

### P3-2. `H1Encoder.crlf` is a computed property allocating `[UInt8]`
`Encoder.swift:261`. `static let crlf: [UInt8] = [0x0D, 0x0A]`.

### P3-3. `HeaderMap.insert` is two-pass (removeAll + append)
`HeaderMap.swift:172-175`. Single-pass find+replace is faster.

### P3-4. `shouldKeepAlive` lowercases the Connection value per request
`Worker.swift:521`. `.lowercased()` allocates a String. ASCII
case-insensitive byte compare would be zero-alloc.

### P3-5. `HTTPCodec/Body/Body.swift` (`HTTPCodecBody`, `Frame`) is dead code
The actual `Body` lives in `HTTP`. This file is orphaned (TODO A24
removed similar dead code; this one survived).

### P3-6. Empty directories in `http-codec`
`HTTPCodec/{Common,Server,Service,Ext}` are empty. `RT/Timer.swift`
exists but is unused.

### P3-7. `PaddedAtomicInt64` duplicated in Pulsar and StarlightCore
`pulsar/Sources/Pulsar/PaddedAtomic.swift` and
`StarlightCore/PaddedAtomic.swift`. Consolidate.

### P3-8. Empty `if jobs.count > 1 {}` in `PollEventLoop.drainJobs`
`PollEventLoop.swift:523-524`. Leftover debug scaffold.

### P3-9. `serve()` doesn't await the drain timer Task
`serve.swift:164-175`. After `timer.cancel()` the timer Task is left
sleeping. `await timer.value` would clean up deterministically.

### P3-10. `Worker` threads are not joined after shutdown
`serve()` returns once drains complete, but worker OS threads may
still be unwinding. Brief zombie window.

### P3-11. `String(decoding: bytes, as: UTF8.self)` is ubiquitous
Forces a heap allocation per call even when the result is compared and
discarded. Many of these are on the hot path (header lookups, method
extraction).

### P3-12. `serve()` ignores `loopCount <= 0`
No workers spawn, `serve()` returns immediately and silently. Should
precondition.

### P3-13. `Response.init(status, from:)` uses `any IntoResponse`
`IntoResponseParts.swift:67`. Existential — can't be inlined. Use a
generic parameter.

### P3-14. `pollfd` magic numbers
`Worker.swift:421`. `events: 0x004` should be `POLLOUT`.

### P3-15. `writeAll` poll timeout (5 s) and `readTimeout` are hardcoded
`Worker.swift:422`. Should be configurable via `serve(...)`.

---

## Test gaps

- No test exercises a body > 8 KB (the test suite would have caught P0-1).
- No test checks that `Transfer-Encoding: chunked` is present on
  streaming responses (would have caught P0-2).
- No test checks the `Allow` header on a 405 (would have caught P1-2).
- No test exercises concurrent connections / Slowloris behavior.
- No test covers HTTP/1.0 keep-alive semantics.
- No test exercises the production `serve()` + `Worker` stack at all —
  all integration tests use `IntegrationServer` (a hand-rolled
  single-threaded blocking server that bypasses `Worker`,
  `PollEventLoop`, and the accept path). The P0-4 / P0-5 / P0-6 /
  P0-7 / P1-1 bugs only manifest through `serve()`.

---

## Recommended order of attack

1. **P0-1** (body cap) — nothing works without this.
2. **P0-2 + P0-3** (hop-by-hop pre-scan) — one fix in `H1Encoder`.
3. **P0-6** (error body drop) — trivial, restores correct error responses.
4. **P0-5** (read timeout) — required before any internet exposure.
5. **P0-4** (bind hang) — required for operability.
6. **P0-7** (EMFILE storm) — required for resilience.
7. Wire the `serve()` stack into the test harness (currently untested).
8. P1 tier, then P2 ergonomics.
