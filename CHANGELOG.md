# Changelog

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
- [`http`](https://github.com/akvilary/http) — http crate port
- [`hyper`](https://github.com/akvilary/hyper) — hyper H1 codec port
- [`mio`](https://github.com/akvilary/mio) — mio epoll primitives port

### Known limitations

- Linux only (epoll backend)
- No WebSocket support (planned)
- No TLS support (planned)
- No HTTP/2 support (planned)
- `~Copyable` not yet applied to hot-path types (planned)
- Handler arity capped at 6 (vs axum's 16)
