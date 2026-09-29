# Changelog

## v0.5.0 (2026-09-29)

Typed-extraction + error-response upgrades that unblock migration of
JSON REST APIs (first consumer: bedone-backend, migrated off
Hummingbird). Bench: ~285K req/s (release, loopback, 12-core, `wrk
-t12 -c100 -d3s`, median of 3 — was ~260K).

### Added

- `JsonConfig` — shared, configurable JSON coders for `Json<T>`:
  process-wide registry (`JsonConfig.setDefault(.iso8601())`) used by
  BOTH decode and encode (zero per-request coder allocation — fixes
  todo D6), plus `JsonConfig.layer(_:)` inserting a per-request
  override into extensions (the `DefaultBodyLimit` pattern). The
  registry is the response-side mechanism: `IntoResponse` has no
  request context to read an extension from — the same constraint
  axum's `Json` has.
- `ResponseError` protocol (`Error & IntoResponse`) + `errorLayer()`:
  thrown domain errors render into their own responses; non-conforming
  errors keep propagating to the server's 500 path. `ExtractionRejection`
  now conforms and renders verbatim when it escapes a closure-style
  handler.
- `PartsHandlerService2/3/4` — typed handlers where every extractor is
  `FromRequestParts` (fixes todo A2: `(State, Path<Id>, Query<…>)`
  combos were inexpressible because arity adapters require the last
  extractor to be `FromRequest`).
- `BodyHandlerService1` — body-only handler (`(Json<T>, State)` etc.).
- `StringKeyedDecoder` upgrades (Path/Query/Form):
  - `Path<UUID>` / single-value top-level decode (exactly one captured
    param, mirrors axum);
  - UUID/Date-style fields via a per-key field decoder;
  - multi-value query keys — `?tags=a&tags=b` decodes into `[String]`,
    `[UUID]`, … (todo: bedone filter contract);
  - all fixed-width integer types + `Float` (several were missing).
- Lingering close in the Worker (nginx `lingering_close`): after an
  error response with a client still uploading, `shutdown(SHUT_WR)` +
  bounded drain (≤1 s / 4 MiB) before close — plain `close(2)` with
  unread bytes sends RST and destroys the already-written response.
  Requires http-codec v0.5.1 (`H1Conn.isClosed()`); drives it on the
  terminal-codec-state and drain-failure paths.
- `ProductionIntegrationTests` — real `serve()`-based integration
  harness (single-loop ProductionServer with controllable shutdown):
  CL-over-limit 413, chunked overrun 413 through the pull path,
  round-trip sanity.

### Changed

- **BREAKING (source)**: `HandlerService0-6` dropped the vestigial,
  never-referenced `Fn` generic parameter. Explicit spellings
  (`HandlerService2<E0, E1, Fn, S, Out>`) must drop it; inference now
  works without explicit generic arguments (README caveat removed).
- `DefaultBodyLimit.read` falls back to the 2 MiB default (was
  `Int.max`) — an unconfigured app must not buffer unbounded bodies;
  raise explicitly via `DefaultBodyLimit.layer` when a route needs
  more (fixes todo C7 together with the mapping below; matches axum).
- Mid-stream body overruns now surface as 413: the Worker's body pull
  maps `H1ConnError.requestTooLarge → BodyError.limitExceeded` and
  other codec errors → `BodyError.ioError`, so body consumers see the
  documented `BodyError` contract instead of an opaque 500.
- Requires http-prism v0.2.1 (`BoxService: HTTPService` conformance —
  the erased service is now accepted by `serve()` directly) and
  http-codec v0.5.1.

### Notes

- `Router.layer` wraps registered endpoints only; 405/404 responses
  synthesized inside `Router.call` bypass layers. Applications that
  need middleware around ALL outcomes (CORS on preflight, trace of
  405s) should compose via `ServiceBuilder().layer(…).service(router)`
  instead — see bedone-backend's `buildApp`.

## v0.4.0 (2026-09-29)

### Changed

- **BREAKING** (stack-wide): the `http` package was renamed to
  [`http-model`](https://github.com/akvilary/http-model) and its
  product/module `HTTP` to `HTTPModel`. Code that spelled
  `import HTTP` alongside starlight must switch to
  `import HTTPModel`; starlight's own module names (Starlight,
  StarlightCore, …) are unchanged. Requires http-model v0.4.0,
  http-codec v0.5.0, http-lens/http-prism v0.2.0.

## v0.3.1 (2026-09-29)

## v0.2.0 (2026-09-25)

### Changed

- **BREAKING**: channel handles are now `ChannelId` instead of `UInt32`
  (`TcpStream`, `Worker`, `PollEventLoopIO`), matching pulsar v0.2.0's
  slab-based channel table: ids carry `(generation << 32) | slot`, so
  slot reuse under connection churn can never misattribute an epoll
  event to a recycled channel. Stale handles now trap fail-fast
  instead of silently acting on the slot's new occupant.

## v0.1.0 (unreleased)

### Added

**Core framework** (port of [axum](https://github.com/tokio-rs/axum)):
- `Router<S>` with nest, merge, layer, route_layer, withState
- `Service<Request, Response>` protocol (port of `tower::Service`)
- `Layer<Request, Response>` struct (port of `tower::Layer`)
- `Handler` protocol with `HandlerService0-6` (up to 6 extractors)
- `IntoResponse` protocol with conformances for String, StatusCode, Result, Json, Redirect, etc.
- `IntoResponseParts` protocol for response composition
- `FromRequest` / `FromRequestParts` extractor protocols

**Extractors** (14 types):
- `State<S>`, `Path<T>`, `Query<T>`, `Json<T>`, `Form<T>`
- `Bytes`, `String`, `Request<Body>`
- `Extension<T>`, `ConnectInfo`, `Host`
- `MatchedPath`, `OriginalUri`
- `Method`, `Uri`, `HeaderMap`

**Middleware** (port of `tower-http`):
- `TraceLayer` — configurable request/response logging
- `TimeoutLayer` — per-request timeout → 504
- `CorsLayer` — CORS preflight + headers (spec-compliant)
- `RateLimitLayer` — per-key sliding-window rate limiter → 429
- `CompressionLayer` — gzip compression via zlib

**HTTP/1.1 server**:
- `serve(service, on:port:)` with auto SIGINT/SIGTERM graceful shutdown
- Thread-per-core via SO_REUSEPORT (N kernel-balanced listeners)
- `Worker` actor with `unownedExecutor` → `PollEventLoop`
- Streaming bodies: `.stream(AsyncSequence)` + chunked Transfer-Encoding
- `Sse<Stream>` structured Server-Sent Events
- `ServeDir` static file serving with MIME + ETag

**Performance**:
- SWAR byte search (8 bytes/iteration)
- Zero-copy `ReadBuffer` (port of `bytes::BytesMut`)
- `writev(2)` multi-buffer output (header + body in one syscall)
- Reusable HeaderMap + Extensions (0 alloc/req after warmup)
- `@inlinable` hot-path functions across module boundaries

**Testing**:
- `TestClient` — in-process testing utility
- `Response.bodyString()` / `bodyJSON<T>()` test helpers

### Performance

- **234K req/s** (release, loopback, 12-core AMD 5600H, `wrk -t12 -c100 -d3s`)
- 1.5× faster than Hummingbird 2 (~150K)

### Packages

- [`starlight`](https://github.com/akvilary/starlight) — axum port
- [`http`](https://github.com/akvilary/http-model) — http crate port
- [`hyper`](https://github.com/akvilary/hyper) — hyper H1 codec port
- [`mio`](https://github.com/akvilary/mio) — mio epoll primitives port

### Known limitations

- Linux only (epoll backend)
- No WebSocket support (planned)
- No TLS support (planned)
- No HTTP/2 support (planned)
- `~Copyable` not yet applied to hot-path types (planned)
- Handler arity capped at 6 (vs axum's 16)
