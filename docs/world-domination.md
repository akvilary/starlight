# Starlight: Plan to Conquer the World

What needs to happen for Starlight to become the go-to SSR framework — not just in Nim, but a serious contender against Go/Rust/Elixir.

---

## Phase 1: Production Ready

Everything a developer needs to build a real app without reaching for another framework.

- [x] **Cookies** — read/write, HttpOnly, Secure, SameSite, Max-Age, expiration
- [x] **Sessions** — in-memory store, pluggable backend (Redis, file), session middleware
- [ ] **CORS middleware** — configurable origins, methods, headers, credentials
- [x] **Typed query parameters** — `handler search(ctx, q: string, page: int = 1)` auto-parsed from `?q=nim&page=2`
- [ ] **Content negotiation** — `withFormats(@["html", "json"])` middleware, auto 406 on unsupported Accept
- [ ] **Validation helpers** — `validate(email, required, isEmail)` with error collection
- [ ] **WebSocket support** — Chronos already supports it, need Starlight-level API
- [ ] **Logging middleware** — structured request logging (method, path, status, duration)
- [ ] **Graceful shutdown** — handle SIGTERM, drain connections

---

## Phase 2: Developer Experience

What makes developers fall in love and tell their friends.

- [ ] **Hot reload in dev mode** — `nim c -r --hotReload main.nim` or file watcher + rebuild
- [ ] **CLI scaffolding** — `starlight new myapp`, `starlight generate handler users`
- [ ] **Error page in dev mode** — rich HTML error page with stack trace, source code context, request dump
- [ ] **Request/response inspector** — dev middleware that logs full request/response bodies
- [ ] **nimble package** — `nimble install starlight` from official repository
- [ ] **Project template** — ready-to-clone repo with layouts, handlers, static files, docker

---

## Phase 3: Prove It With Numbers

Nobody believes "fastest" without benchmarks. This is the marketing moment.

- [ ] **Benchmark suite** — standardized tests: plaintext, JSON, single query, multiple queries, fortunes (TechEmpower style)
- [ ] **vs Nim frameworks** — Prologue, HappyX, Jester, Mummy
- [ ] **vs other languages** — Go (Fiber, Echo), Rust (Actix, Axum), Elixir (Phoenix), Crystal (Lucky), Node (Fastify)
- [ ] **Benchmark page on GitHub** — auto-generated, reproducible, CI-updated
- [ ] **Memory profiling** — prove 1 allocation / 0 copies claim with numbers: RSS, allocations per request
- [ ] **Compile-time vs runtime comparison** — same page rendered with Starlight vs string concatenation, show the difference

**Key metrics to highlight:**
- Requests/sec (throughput)
- p99 latency
- Memory per request
- Binary size
- Compile time

---

## Phase 4: Community & Adoption

Turn users into advocates.

- [ ] **Killer demo app** — blog or task manager with HTMX, showing: layouts, handlers, middleware, forms, sessions, CDN, error pages, urlFor
- [ ] **Tutorial series** — step-by-step: "Build a blog with Starlight in 30 minutes"
- [ ] **API documentation** — auto-generated from doc comments
- [ ] **GitHub Actions CI** — test on Linux/macOS/Windows, multiple Nim versions
- [ ] **Contributing guide** — architecture overview, how to add features, PR process
- [ ] **Nim Forum / Discord announcement** — "Here's Starlight, here are the benchmarks, here's why"
- [ ] **Blog post** — "How compile-time HTML optimization makes Starlight the fastest SSR in Nim"
- [ ] **Hacker News / Reddit launch** — after benchmarks and demo app are polished

---

## Phase 5: Ecosystem

What keeps people long-term.

- [ ] **Database integration guide** — examples with norm, allographer, db_connector
- [ ] **Authentication package** — JWT, session-based, OAuth2 helpers (separate nimble package)
- [ ] **HTMX integration guide** — patterns for partial page updates, out-of-band swaps
- [ ] **Deployment guide** — Docker, systemd, nginx reverse proxy, SSL termination
- [ ] **VS Code extension** — syntax highlighting for `layout`/`handler`/`middleware` macros
- [ ] **Pagination module** — `paginate(seq, page, perPage)` + layout component
- [ ] **Rate limiting middleware**
- [ ] **Compression middleware** — gzip/brotli response compression

---

## The Starlight Pitch (one paragraph)

Starlight is a Nim SSR framework that pre-computes HTML at compile time. Static markup is baked into the binary — only dynamic expressions run at runtime. Nested layouts share a single buffer with zero intermediate allocations. The entire render-to-response pipeline is 1 allocation, 0 copies. Handlers have typed parameters. Routes are compile-time validated entities. URL generation is checked by the compiler. It's the framework where the compiler is your test suite.

---

## What We Already Have (unique advantages)

- Compile-time HTML splitting (no other Nim framework does this)
- Shared buffer mode with lazy parameters (zero-alloc nesting)
- 1 allocation, 0 copies rendering pipeline (ORC move semantics)
- Typed path parameters with compile-time validation
- RouteRef entities with compile-time URL generation (urlFor/urlAs)
- PrefixTree router
- Middleware chain with explicit next
- CDN proxy (no other Nim framework has this)
- Form parsing with multipart file uploads
- Custom error pages
- Internal dispatch (ctx.forward) with relative paths
- RelRef/AbsRef for relative URL generation
