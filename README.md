# Starlight

High-performance HTTP framework for Swift 6.2+, ported 1:1 from Rust's [axum](https://github.com/tokio-rs/axum).

**234K req/s** on a 12-core AMD 5600H (loopback, `wrk -t12 -c100 -d3s`).

## Quickstart

```swift
import Starlight
import StarlightServer

let app = Router(state: NoState())
    .get("/") { _ in .plain("Hello, World!") }
    .get("/users/:id") { req in
        // Path params, JSON, Query — all type-safe extractors
        .plain("user lookup")
    }
    .get("/events") {
        // SSE streaming via chunked Transfer-Encoding
        Sse(MyEventStream())
    }

try await serve(app, on: "0.0.0.0", port: 8080)
```

```bash
swift run -c release hello-world
curl http://localhost:8080/
```

## Features

- **axum 1:1 architecture** — Router<S>, Service<Request>, Layer, Handler, Extractors
- **234K req/s** — thread-per-core, SO_REUSEPORT, epoll via [mio](https://github.com/akvilary/mio)
- **Zero-copy I/O** — ReadBuffer (port of `bytes::BytesMut`), writev(2)
- **Streaming bodies** — `.stream(AsyncSequence)` + chunked Transfer-Encoding
- **Graceful shutdown** — SIGINT/SIGTERM auto-handled, 30s drain
- **14 extractors** — State, Path, Query, Json, Form, Bytes, Extension, ConnectInfo, Host, MatchedPath, OriginalUri, Body, String, Request
- **Middleware** — TraceLayer, TimeoutLayer, CorsLayer, RateLimitLayer, CompressionLayer (gzip)
- **Static files** — ServeDir with MIME detection + ETag
- **SSE** — `Sse<Stream>` structured Server-Sent Events
- **HandlerService0-6** — up to 6 typed extractors per handler

## Architecture

```
../mio        → mio crate (epoll primitives: Poll, Registry, Token)
../http       → http crate (Request, Response, Method, StatusCode, Body)
../hyper      → hyper crate (H1 codec: Conn, Decoder, Encoder, Dispatcher)
starlight     → axum crate (Router, Handler, Extractors, Middleware, Server)
```

| Swift module | Rust analogue |
|---|---|
| `StarlightTower` | `tower::{Service, Layer}` |
| `StarlightHTTP` (→ `../http`) | `http` crate |
| `StarlightServer` (→ `../hyper`) | `hyper::server` + `tokio::net` |
| `StarlightCore` | `axum-core` (Handler, IntoResponse, FromRequest) |
| `StarlightRouting` | `axum::routing` (Router<S>, MethodRouter) |
| `StarlightExtractors` | `axum::extract` (State, Path, Query, Json, Form) |
| `StarlightMiddleware` | `axum::middleware` + `tower-http` |
| `StarlightPoll` | `tokio::runtime` (epoll reactor) |

## Performance

| Framework | req/s | Notes |
|---|---|---|
| **Starlight** | **234K** | release, loopback, 12-core AMD 5600H |
| Hummingbird 2 | ~150K | 1.5× slower |
| Go net/http | ~200-300K | parity |
| Rust axum | ~400-500K | below (Swift vs Rust runtime overhead) |

Optimizations:
- SWAR byte search (8 bytes/iteration for `\r\n\r\n`)
- Zero-copy ReadBuffer (no memcpy between read(2) and parse)
- writev(2) — header + body in one syscall
- Reusable HeaderMap + Extensions — 0 alloc/req after warmup
- Per-connection Task (not per-request) — amortized over keep-alive

## Extractors

```swift
// Type-safe path params
struct UserId: Decodable { let id: Int }
router.get("/users/:id") { (path: Path<UserId>) in ... }

// Query string decoding
struct Filter: Decodable { let active: Bool; let limit: Int }
router.get("/users") { (query: Query<Filter>) in ... }

// JSON body
struct CreateUser: Decodable { let name: String }
router.post("/users") { (json: Json<CreateUser>) in ... }

// Application state
router.get("/db") { (state: Extension<Database>) in ... }

// Form data
struct Login: Decodable { let email: String; let password: String }
router.post("/login") { (form: Form<Login>) in ... }
```

## Middleware

```swift
let app = ServiceBuilder<Request<Body>, Response<Body>>()
    .layer(CompressionLayer().asLayer())      // gzip
    .layer(TraceLayer(config: .stderr).asLayer())  // request logging
    .layer(CorsLayer().asLayer())             // CORS headers
    .layer(TimeoutLayer(duration: .seconds(30)).asLayer())  // slow-loris defence
    .layer(RateLimitLayer(limiter: RateLimiter(maxRequests: 100)).asLayer())  // rate limit
    .service(router)
```

## Installation

```swift
.package(url: "https://github.com/akvilary/starlight.git", branch: "axum-arch")
```

**Linux only** — uses epoll via [mio](https://github.com/akvilary/mio).

## Graceful Shutdown

Ctrl-C or `kill -TERM` triggers graceful drain — in-flight requests
complete (up to 30s), then the server exits. No explicit setup needed.

```bash
swift run -c release hello-world 8080
# Ctrl-C → drains in-flight requests → exits cleanly
```

## License

MIT
