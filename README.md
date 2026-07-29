# Starlight

High-performance HTTP framework for Swift 6.2+, ported 1:1 from Rust's [axum](https://github.com/tokio-rs/axum).

**~260K req/s** on a 12-core AMD 5600H (loopback, `wrk -t12 -c100 -d3s`).

## Quickstart

```swift
import Starlight  // re-exports Routing, Core, Extractors, Server, HTTPLens, …

let app = Router(state: NoState())
    .get("/") { _ in .plain("Hello, World!") }
    .get("/health") { .plain("ok") }

installShutdownSignalHandlers()
try await serve(
    app,
    on: "0.0.0.0", port: 8080,
    onShutdown: { await waitForShutdownSignal() }
)
```

```bash
swift run -c release hello-world
curl http://localhost:8080/
```

## Features

- **axum 1:1 architecture** — `Router<S>`, `Service<Request>`, `Layer`, `Handler`, extractors
- **~260K req/s** — thread-per-core, `SO_REUSEPORT`, epoll via [mio](https://github.com/akvilary/mio), driven by [pulsar](https://github.com/akvilary/pulsar)
- **Zero-copy I/O** — `ReadBuffer` (port of `bytes::BytesMut`), `writev(2)`
- **Streaming bodies** — `Body.stream(AsyncSequence)` + chunked Transfer-Encoding
- **SSE** — `Sse<Stream>` structured Server-Sent Events
- **Graceful shutdown** — SIGINT/SIGTERM → 30s drain (see below)
- **Extractors** — State, Path, Query, Json, Form, Bytes, String, Extension, ConnectInfo, Host, MatchedPath, OriginalUri, Method, Uri, HeaderMap, Request
- **Middleware** — TraceLayer, TimeoutLayer, CorsLayer, RateLimitLayer, CompressionLayer (gzip), `from_fn`
- **Static files** — `ServeDir` with MIME detection + ETag
- **HandlerService0-6** — up to 6 typed extractors per handler

## Architecture

Starlight is the umbrella crate of a 7-package workspace, each mirroring a
piece of the tokio / tower / axum ecosystem:

```
mio          → epoll primitives (Poll, Registry, Token, Events, Waker)
pulsar       → tokio::runtime — SerialExecutor + TaskExecutor on epoll
http         → http crate (Request, Response, Method, StatusCode, Body, HeaderMap)
http-codec   → hyper H1 codec (Conn, Decoder, Encoder, Dispatcher)
http-prism   → tower::{Service, Layer, ServiceBuilder, BoxService}
http-lens    → tower-http (Compression, Trace, Cors, Timeout, RateLimit, from_fn)
starlight    → axum (Router, Handler, Extractors, serve())
```

| Module / package | Rust analogue |
|---|---|
| `Starlight` | `axum` umbrella + `serve()` |
| `StarlightCore` | `axum-core` (Handler, IntoResponse, FromRequest) |
| `StarlightRouting` | `axum::routing` (Router<S>, MethodRouter, Fallback) |
| `StarlightExtractors` | `axum::extract` (State, Path, Query, Json, Form) |
| `StarlightServer` | `hyper::server` + `tokio::net` (TcpListener, serve) |
| `HTTPPrism` ([http-prism](https://github.com/akvilary/http-prism)) | `tower::{Service, Layer}` |
| `HTTPLens` ([http-lens](https://github.com/akvilary/http-lens)) | `axum::middleware` + `tower-http` |
| `HTTP` ([http](https://github.com/akvilary/http)) | `http` crate |
| `HTTPCodec` ([http-codec](https://github.com/akvilary/http-codec)) | `hyper` H1 codec |
| `Pulsar` ([pulsar](https://github.com/akvilary/pulsar)) | `tokio::runtime` (epoll reactor) |
| `MIO` ([mio](https://github.com/akvilary/mio)) | `mio` (epoll primitives) |
| `CLinuxExt` | libc wrappers (`accept4`, `sched_setaffinity`, `sigaction`) |

## Performance

| Framework | req/s | Notes |
|---|---|---|
| **Starlight** | **~260K** | release, loopback, 12-core AMD 5600H |
| Hummingbird 2 | ~150K | ~1.7× slower |
| Go net/http | ~200–300K | parity |
| Rust axum | ~400–500K | below (Swift vs Rust runtime overhead) |

Optimizations:

- SWAR byte search (8 bytes/iteration for `\r\n\r\n`)
- Zero-copy `ReadBuffer` (no memcpy between `read(2)` and parse)
- `writev(2)` — header + body in one syscall
- Reusable `HeaderMap` + `Extensions` — 0 alloc/req after warmup
- Per-connection Task (not per-request) — amortized over keep-alive
- `@inlinable` hot paths across module boundaries

## Extractors

Closure handlers receive the raw `Request` (or no args) — the axum `get(|req| …)`
shape. Path params land in `request.extensions` under `MatchedPathParams`, and
bodies decode via the `FromRequest` / `FromRequestParts` extractor protocols:

```swift
struct CreateUser: Decodable { let name: String }

let app = Router(state: NoState())
    .get("/users/:id") { req -> Response in
        let id = req.extensions.get(MatchedPathParams.self)?.params.get("id") ?? "?"
        return .plain("user \(id)")
    }
    .post("/users") { req -> Response in
        // Json<T> is FromRequest — reads + decodes the body, rejects 400 on failure
        let json = try await Json<CreateUser>.fromRequest(req, state: NoState())
        return .plain("creating \(json.value.name)")
    }
    .get("/ping") { .plain("pong") }   // zero-arg closure
```

Available extractors: `State<S>`, `Path<T>`, `Query<T>`, `Json<T>`,
`Form<T>`, `Bytes`, `String`, `Extension<T>`, `ConnectInfo`, `Host`,
`MatchedPath`, `OriginalUri`, `Method`, `Uri`, `HeaderMap`, `Request`.

The `HandlerService0`…`HandlerService6` adapters wire extractors into the
`Service` dispatch chain (last extractor may consume the body via
`FromRequest`). Note: their closure-style construction currently requires
explicit generic arguments due to an unused type parameter, so the manual
`Request` form above is the smoother path today.

## Middleware

Layers are applied directly on the `Router` (axum-style) — no manual
`ServiceBuilder` needed. Each `*Layer` is a concrete struct that becomes a
`Layer<Request, Response>` via `.asLayer()`:

```swift
let app = Router(state: NoState())
    .get("/", { _ in .plain("Hello, World!") })
    // outermost-first: compression wraps everything below
    .layer(CompressionLayer().asLayer())                 // gzip (auto by Accept-Encoding)
    .layer(TraceLayer(config: .stderr).asLayer())        // request logging
    .layer(CorsLayer().asLayer())                        // CORS headers
    .layer(TimeoutLayer(duration: .seconds(30)).asLayer())   // → 504 on timeout
    .layer(RateLimitLayer(limiter: RateLimiter(maxRequests: 100)).asLayer())  // → 429
```

Or write middleware inline with `from_fn`:

```swift
.layer(from_fn { request, next in
    print("→ \(request.uri.pathString)")
    let response = try await next.run(request)
    print("← \(response.status)")
    return response
})
```

Use `.route_layer(...)` instead of `.layer(...)` to scope middleware to only
the routes added before the call.

## Static files

```swift
let app = Router(state: NoState())
    .fallback(BoxService(ServeDir(root: "./public")))
```

`ServeDir` maps the request path under the root, detects MIME type by extension,
and emits an `ETag` from the file modification time.

## Graceful shutdown

`serve(onShutdown:)` blocks on the closure you pass; when it returns, the server
stops accepting and drains in-flight requests (up to `drainTimeout`, default 30s)
before exiting. Wire it to SIGINT/SIGTERM with the helpers from `StarlightServer`:

```swift
import Starlight  // StarlightServer is re-exported

installShutdownSignalHandlers()           // sigaction(SIGINT, SIGTERM) — SA_RESTART
try await serve(
    app, on: "0.0.0.0", port: 8080,
    drainTimeout: .seconds(30),
    onShutdown: { await waitForShutdownSignal() }   // resumes on Ctrl-C / kill -TERM
)
```

```bash
swift run -c release hello-world 8080
# Ctrl-C → stops accepting → drains in-flight requests → exits cleanly
```

## Installation

```swift
.package(url: "https://github.com/akvilary/starlight.git", branch: "main")
```

The remaining packages are resolved automatically as dependencies:

```swift
.product(name: "Starlight", package: "starlight")        // umbrella + serve()
```

**Linux only** — uses epoll via [mio](https://github.com/akvilary/mio).

## Status

| Component | Status |
|---|---|
| HTTP/1.1 end-to-end pipeline | ✅ |
| Router (nest, merge, layer, route_layer, withState) | ✅ |
| Extractors + HandlerService0-6 | ✅ |
| Middleware (Trace, Timeout, Cors, RateLimit, Compression, from_fn) | ✅ |
| Streaming bodies + SSE + ServeDir | ✅ |
| Graceful shutdown | ✅ |
| WebSocket | ❌ planned |
| TLS | ❌ planned |
| HTTP/2 | ❌ planned |

## License

MIT
