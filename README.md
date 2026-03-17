# Starlight

Super fast server-side rendering framework for Nim.

Starlight combines the stability of Prologue with the ergonomics of HappyX, while adding compile-time HTML optimization that makes it the fastest SSR framework in the Nim ecosystem.

## Features

- **Built on [Chronos](https://github.com/status-im/nim-chronos)** — async engine and HTTP server from the Status team, battle-tested in production.
- **Compile-time HTML optimization** — static parts of templates are pre-computed and baked into the binary. Only dynamic expressions are evaluated at runtime.
- **Native Nim syntax in HTML DSL** — no special syntax like `{var}` or `x->inc()`. Just write normal Nim code inside `layout` blocks.
- **PrefixTree router** — typed path parameters (`{id:int}`, `{slug}`, `{price:float}`) with compile-time validation.
- **Middleware chain** — explicit `next` callback pattern for predictable handler processing.
- **Zero-overhead layouts** — `layout` generates inline procs with implicit context passing.
- **Single allocation rendering** — the HTML engine pre-calculates buffer size and builds the entire page in one string.
- **Shared buffer mode (`{.buf.}`)** — nested layouts write to a single shared buffer with zero intermediate allocations. Buffer capacity is computed at compile time. The final string is moved (not copied) through the entire response chain thanks to Nim's ORC move semantics.

## Installation

```
nimble install starlight
```

Or add to your `.nimble` file:

```nim
requires "starlight >= 0.1.0"
```

## Quick Start

```nim
import starlight

layout HomePage():
  Html:
    Head:
      Title: "Hello Starlight"
    Body:
      H1: "It works!"

handler home() {.html.}:
  return HomePage()

route Main:
  get("", home)

var router = newRouter()
router.mount("/", Main)
router.serve("127.0.0.1", 5000)
```

Run:

```
nim c -r main.nim
# Starlight listening on http://127.0.0.1:5000
```

The project ships with `nim.cfg` that sets `--mm:orc` explicitly. ORC provides move semantics for zero-copy rendering and is thread-safe for multi-threaded HTTP serving.

## Layouts

`layout` creates reusable HTML templates. HTML tags are only available inside `layout` bodies. Context (`ctx`) is passed implicitly between layouts.

### Basic Layout

```nim
layout Card(title: string, body: string, footer = ""):
  Div(class="card"):
    H2(class="card-title"): title
    P(class="card-body"): body
    if footer != "":
      Div(class="card-footer"): footer
```

### Nested Layouts

Use `{.buf.}` layouts for nesting — all nested calls write to a single shared buffer with zero intermediate allocations (see [Shared Buffer Mode](#shared-buffer-mode)):

```nim
layout NavBar() {.buf.}:
  Nav:
    A(href="/"): "Home"
    raw " | "
    A(href="/about"): "About"

layout Page(pageTitle: string) {.buf.}:
  Html:
    Head:
      Meta(charset="utf-8")
      Title: pageTitle
    Body:
      NavBar()
      Hr
      Main:
        H1: "Welcome"
```

Nesting also works without `{.buf.}`, but each layout creates its own string buffer and the results are concatenated — this is slower due to extra allocations and copies:

```nim
layout NavBar():
  Nav:
    A(href="/"): "Home"

layout Page(pageTitle: string, content: string):
  Html:
    Body:
      raw NavBar()       # NavBar() returns a string, copied into Page's buffer
      raw content        # same — extra allocation + copy
```

### Using Third-Party Template Engines

Starlight works with any template engine that returns a string. For example, with [Nimja](https://github.com/enthus1ast/nimja):

```nim
import nimja

proc renderArticle(title: string): string =
  compileTemplateStr("templates/article.nimja")

layout Page(title: string) {.buf.}:
  Html:
    Body:
      raw renderArticle("Hello")
```

### Using Layouts in Handlers

Layouts are called like regular functions. `ctx` is passed implicitly:

```nim
handler home() {.html.}:
  return Page(pageTitle="Home", content=Card(title="Welcome", body="Hello!"))
```

### HTML Tags

HTML tags are only available inside `layout` bodies. Tags are written in TitleCase (`Div`, `H1`, `P`, `A`) and output as lowercase HTML (`<div>`, `<h1>`, `<p>`, `<a>`). Attributes are passed as named parameters. Void tags (`Br`, `Hr`, `Img`, `Input`, etc.) self-close automatically.

```nim
layout MyPage():
  H1: "Hello World"
  P: "A paragraph"
  A(href="/about"): "About"
  Img(src="/logo.png", alt="Logo")
  Br
```

TitleCase eliminates all conflicts with Nim keywords — no aliases needed for `Div`, `Object`, `Template`, or `Var`.

### Dynamic Content

Variables and expressions work as normal Nim code. Dynamic content is inserted **without escaping** for maximum performance — the developer is responsible for escaping user input when needed (use `escapeHtml` function):

```nim
layout Greeting(userName: string, messageCount: int):
  H1: "Hello, " & userName & "!"
  P: "You have " & $messageCount & " messages"
```

### Control Flow

Standard Nim control flow works inside layouts:

```nim
layout UserNav(loggedIn: bool, userName: string):
  if loggedIn:
    P: "Welcome back, " & userName
    A(href="/logout"): "Logout"
  else:
    A(href="/login"): "Login"

layout ItemList(items: seq[string]):
  Ul:
    for item in items:
      Li: item
```

### Raw HTML and Escaping

`raw` inserts content **without escaping** — use for pre-rendered HTML or trusted strings:

```nim
layout ArticleView(content: string, author: string):
  Div(class="article"):
    raw content              # trusted HTML, no escaping
  P:
    raw "Written by "
    Strong: author
```

For user input or untrusted data, use the `escapeHtml` function explicitly:

```nim
layout Comment(userInput: string):
  P: escapeHtml(userInput)   # safe: <script> → &lt;script&gt;
```

## Handlers

The `handler` macro generates a proc with the `HandlerProc` signature:

```nim
type HandlerProc = proc(ctx: Context): Future[Response] {.
    async: (raises: [CatchableError]), gcsafe.}
```

Every handler — regardless of path parameters or pragmas — is a `HandlerProc`. Path parameters declared in the handler signature are syntactic sugar: the macro extracts them from `ctx.pathParams` inside the proc body:

```nim
# What you write:
handler getUser(name: string) {.html.}:
  return UserProfile(name=name)

# What the macro generates:
proc getUser*(ctx: Context): Future[Response] {.
    async: (raises: [CatchableError]), gcsafe.} =
  let name = ctx.pathParams["name"]
  return answer(UserProfile(name=name))
```

This means all handlers have the same signature and are fully compatible with middleware. The router populates `ctx.pathParams` before the middleware chain runs, so middleware like `withTimeout` works identically for handlers with and without path parameters.

Use pragmas to specify the response type:

- `{.html.}` — wraps `return` expressions in `answer()` (Content-Type: text/html)
- `{.json.}` — wraps `return` expressions in `answerJson()` (Content-Type: application/json)
- *(no pragma)* — no wrapping, `return` must provide a `Response` directly

If no `return` is specified, the handler returns `Http200` with an empty body.

### HTML Handler

```nim
handler home() {.html.}:
  return Page(pageTitle="Home", content=HomePage())

# Equivalent to:
# proc home(ctx: Context): Future[Response] {.async, gcsafe.} =
#   return answer(Page(pageTitle="Home", content=HomePage()))
```

### JSON Handler

```nim
handler getStatus() {.json.}:
  return %*{"status": "ok", "version": "0.1.0"}

# Equivalent to:
# proc getStatus(ctx: Context): Future[Response] {.async, gcsafe.} =
#   return answerJson(%*{"status": "ok", "version": "0.1.0"})
```

### Custom HTTP Status Code

To return a response with a custom status code, use a tuple `(body, HttpCode)`:

```nim
handler unauthorized() {.json.}:
  return (%*{"error": "not authorized"}, Http401)

handler notFound() {.html.}:
  return (Page(title="404", content=NotFound()), Http404)
```

### Raw Response Handler

```nim
handler customHandler():
  return answer("plain text", Http200)
```

### Default Response

If no `return` is specified, the handler returns `Http200` with an empty body (`""`):

```nim
handler fireAndForget():
  echo "doing work, no return"
  # return "" # Http200
```

### JSON from Pre-Serialized String

`answerJson` accepts both `JsonNode` (serializes automatically) and `string` (sends as-is). This is useful when you have cached or pre-built JSON:

```nim
# JsonNode — serialized by the framework:
handler getStatus() {.json.}:
  return %*{"status": "ok"}

# Pre-serialized string — zero serialization overhead:
handler getCached() {.json.}:
  return cachedJsonString

# Without macro:
proc getCached(ctx: Context): Future[Response] {.async, gcsafe.} =
  return answerJson(cachedJsonString)
```

### Path Parameters

Supported parameter types in the handler signature:

| Type | Conversion |
|------|------------|
| `string` | No conversion (default) |
| `int` | `parseInt(ctx.pathParams[key])` |
| `float` | `parseFloat(ctx.pathParams[key])` |
| `bool` | `parseBool(ctx.pathParams[key])` |

```nim
handler getUser(name: string) {.html.}:
  return Page(pageTitle=name, content=UserProfile(name=name))

handler getItem(id: int) {.json.}:
  let item = fetchItem(id)
  return %*{"id": id, "name": item.name}
```

### Accessing Request Context

The `ctx` object is available in every handler:

```nim
handler search() {.json.}:
  let query = ctx.getQuery("q")
  let token = ctx.request.headers["Authorization"]
  let data = parseJson(ctx.request.body)
  return %*{"query": query, "ip": ctx.request.ip}
```

## Routing

### Route Groups

Define route groups with the `route` macro. Two syntaxes are supported:

```nim
# Reference a handler proc:
route UsersApi:
  get("", listUsers)
  get("/{name}", getUser)
  post("", createUser)

# Inline body:
route ApiRoutes:
  get("/status", getStatus)
  post("/echo", echoBody)
  get("/health"):
    return answer("OK")
```

Supported HTTP methods: `get`, `post`, `put`, `patch`, `delete`, `head`, `options`.

### Path Parameters

Path parameters are defined with `{name:type}` syntax:

| Syntax          | Nim type  | Example match    |
|-----------------|-----------|------------------|
| `{id:int}`      | `int`     | `/users/42`      |
| `{price:float}` | `float`   | `/items/9.99`    |
| `{active:bool}` | `bool`    | `/filter/true`   |
| `{slug}`        | `string`  | `/posts/my-post` |
| `{name:string}` | `string`  | `/users/alice`   |

Type validation happens during route matching — if `{id:int}` receives a non-numeric value, the route won't match (404).

### Mounting Routes

Mount route groups on the router with a prefix:

```nim
var router = newRouter()
router.mount("/users", UsersApi)
router.mount("/api", ApiRoutes)
router.mount("/", Pages)
router.serve("127.0.0.1", 5000)
```

Routes are combined: a `get "/{id}"` inside `UsersApi` mounted at `/users` becomes `GET /users/{id}`.

## Middleware

Middleware functions wrap handlers with a `next` callback:

```nim
proc loggingMiddleware(ctx: Context, next: HandlerProc): Future[Response] {.
    async: (raises: [CatchableError]), gcsafe.} =
  echo ctx.httpMethod, " ", ctx.path
  result = await next(ctx)

proc authMiddleware(ctx: Context, next: HandlerProc): Future[Response] {.
    async: (raises: [CatchableError]), gcsafe.} =
  if ctx.request.headers.hasKey("Authorization"):
    result = await next(ctx)
  else:
    result = answerJson(%*{"error": "Unauthorized"}, Http401)
```

Register middleware globally:

```nim
var router = newRouter()
router.use(loggingMiddleware)
router.use(authMiddleware)
```

Execution order: middlewares run in registration order. Each middleware can choose to call `next` (continue) or not (stop the chain).

### Built-in Middleware

Starlight ships with ready-to-use middleware helpers. Each returns a `MiddlewareProc` that can be used globally via `router.use()` or per-route.

#### `withTimeout(ms)`

Aborts handler execution after `ms` milliseconds. Returns `Http408 Request Timeout` if the deadline is exceeded:

```nim
# Global — all routes get a 5-second deadline:
router.use(withTimeout(5000))

# Per-route — only this group has a timeout:
route ApiRoutes:
  get("/slow", slowHandler, @[withTimeout(3000)])
```

Internally, `withTimeout` calls Chronos `wait()` on the handler future and catches `AsyncTimeoutError`:

```nim
# What withTimeout(2000) does:
proc(ctx: Context, next: HandlerProc): Future[Response] {.
    async: (raises: [CatchableError]), gcsafe.} =
  try:
    return await next(ctx).wait(milliseconds(2000))
  except AsyncTimeoutError:
    return Response(code: Http408, body: "Request Timeout",
                    headers: HttpTable.init([("Content-Type", "text/plain")]))
```

### Writing Custom Middleware

Any proc matching `MiddlewareProc` signature works as middleware:

```nim
type MiddlewareProc = proc(ctx: Context, next: HandlerProc): Future[Response] {.
    async: (raises: [CatchableError]), gcsafe.}
```

Example — response timing header:

```nim
proc withTiming(ctx: Context, next: HandlerProc): Future[Response] {.
    async: (raises: [CatchableError]), gcsafe.} =
  let start = Moment.now()
  result = await next(ctx)
  let elapsed = Moment.now() - start
  result.headers.add("X-Response-Time", $elapsed)
```

## Internal Dispatch

`ctx.forward` dispatches a request internally through the router. The client receives one response and never knows about the forward. All middleware of the target route is applied.

```nim
handler oldEndpoint() {.json.}:
  return await ctx.forward(MethodGet, "/api/v2/data")
```

The router reference is stored in `ctx` automatically, so `forward` works from any handler without extra imports.

`forward` creates a lightweight clone of the context — only `path`, `httpMethod` and `pathParams` are new. Request data (headers, body, query, ip) is shared via a single `RequestData` ref, not copied.

### Absolute and Relative Paths

`forward` resolves paths relative to the current `ctx.path`:

```nim
# Current request path: /users/alice

await ctx.forward(MethodGet, "/items/42")        # absolute → /items/42
await ctx.forward(MethodGet, "./profile")         # relative → /users/alice/profile
await ctx.forward(MethodGet, "../bob")            # up one   → /users/bob
await ctx.forward(MethodGet, "../../admin/panel") # up two   → /admin/panel
```

### Forward vs Redirect

| | `ctx.forward` | `redirect` |
|---|---|---|
| Where | Server-side | Client-side |
| HTTP requests | 1 | 2 |
| Middleware | Applied on target route | New request from client |
| Client URL | Does not change | Changes to new URL |
| Context | Cloned (original not mutated) | New request, new context |

## Compile-Time Optimization

Starlight's key advantage: the HTML engine analyzes templates at compile time and separates static from dynamic parts.

```nim
layout MyPage(userName: string, bio: string):
  Head:
    Title: "My App"
    Meta(charset="utf-8")
  Body:
    H1: userName
    P: bio
```

Generated code (conceptually):

```nim
var buf = newStringOfCap(256)
buf.add "<head><title>My App</title><meta charset=\"utf-8\"/></head><body><h1>"
buf.add $userName               # only runtime work
buf.add "</h1><p>"
buf.add $bio                    # only runtime work
buf.add "</p></body>"
```

On a typical page where 80-90% is static markup, this means near-zero runtime overhead.

## Shared Buffer Mode

By default, each `layout` creates its own string buffer, fills it, and returns the result. When layouts are nested via `raw`, the inner layout allocates a separate buffer, returns it as a string, and the outer layout copies it in. For a page with 5 nested components, that means 5 allocations + 4 copies.

The `{.buf.}` pragma eliminates this overhead. All nested `{.buf.}` layouts write to **one shared buffer** — zero intermediate allocations.

### How It Works

Add `{.buf.}` to any layout:

```nim
layout SiteHeader() {.buf.}:
  Header:
    H1: "My Site"

layout Page(title: string, content: string) {.buf.}:
  Html:
    Head:
      Title: title
    Body:
      SiteHeader()   # {.buf.} → writes to the same buffer, no allocation
      raw content    # regular layout → returns string, added to buffer
```

A `{.buf.}` layout automatically detects its calling context at compile time via `when declared(buf)`:

**Called from a handler** (no `buf` in scope):

```nim
handler home() {.html.}:
  return Page(title="Hello")

# What actually happens:
#   1. Page template sees declared(buf) = false
#   2. Creates: var buf = newStringOfCap(Page_staticCap)
#   3. Calls __layout__Page(ctx, buf, title) — fills buf
#      (all nested {.buf.} layouts write to this same buf)
#   4. Returns buf as string
#   5. answer(buf) — moves the string into Response.body (zero copies, ORC move semantics)
```

One allocation, one buffer for the entire page. The string is never copied — it is moved through the `answer()` → `Response.body` → HTTP send chain.

**Called inside another `{.buf.}` layout** (`buf` already in scope):

```nim
layout Page(title: string) {.buf.}:
  Html:
    Body:
      SiteHeader()   # SiteHeader sees declared(buf) = true
                      # → calls __layout__SiteHeader(ctx, buf) directly
                      # → writes to the SAME buf, returns ""
                      # Zero allocation, zero copy
```

The nested layout writes to the parent's buffer and returns an empty string (which the DSL discards as a no-op).

**Regular layouts** (without `{.buf.}`) always return strings. Use `raw` to embed them inside other layouts, as before.

### Lazy Parameters

**The problem.** A `{.buf.}` layout that takes a `content: string` parameter and embeds it via `raw content` has a broken buffer order: the parameter is evaluated **before** the layout body runs. If `content` is another `{.buf.}` layout call, it writes to the buffer too early — before the parent's `<html><body>` tags.

**The solution.** Declare the parameter as `lazyLayout` — the expression is wrapped in a `nimcall` proc and called at the exact position in the layout body where the parameter name appears:

```nim
layout Shell(title: string, content: lazyLayout) {.buf.}:
  Html:
    Head:
      Title: title
    Body:
      content          # ← closure is called HERE, writing to buffer at this position
      Footer:
        P: "Powered by Starlight"

layout HomePage(title: string) {.buf.}:
  Shell(title=title, lazy content=SiteHeader())
  #                   ^^^^ lazy keyword wraps SiteHeader() in a nimcall proc
```

`lazy content=expr` defers evaluation of `expr` until the layout body reaches the `content` position. The `{.buf.}` layout `SiteHeader()` writes directly to the shared buffer at the correct position.

Multiple lazy parameters are supported:

```nim
layout TwoColumn(sidebar: lazyLayout, main: lazyLayout) {.buf.}:
  Div(class="page"):
    Div(class="sidebar"):
      sidebar
    Div(class="content"):
      main

layout SidebarNav() {.buf.}:
  Nav:
    A(href="/"): "Home"

layout DashboardContent() {.buf.}:
  H1: "Dashboard"
  P: "Welcome back."

layout DashboardPage() {.buf.}:
  TwoColumn(lazy sidebar=SidebarNav(), lazy main=DashboardContent())
```

**Forwarding.** A lazy parameter can be passed down to a nested layout:

```nim
layout Inner(content: lazyLayout) {.buf.}:
  Div(class="inner"):
    content

layout Outer(content: lazyLayout) {.buf.}:
  Div(class="outer"):
    Inner(lazy content=content)    # forwards the proc, no re-wrapping
```

**Using and forwarding.** A lazy parameter can be both called (written to buffer) and forwarded in the same layout:

```nim
layout Outer(content: lazyLayout) {.buf.}:
  content                           # writes content to buffer here
  Inner(lazy content=content)       # AND forwards to Inner (writes again)
```

### Buffer Capacity

Each `{.buf.}` layout exports a compile-time constant `Name_staticCap` computed from:

| Component | Source |
|-----------|--------|
| Static HTML bytes | Counted from string literals in generated code |
| Dynamic expressions | Number of runtime values × 64 bytes each |
| Nested `{.buf.}` layouts | Sum of their `_staticCap` constants |
| Margin | +256 bytes |

The top-level layout uses this constant for `newStringOfCap`. If the page exceeds the estimate (e.g. a large dynamic list), Nim's string auto-grows (2x doubling, amortized O(1)).

For layouts with unpredictable dynamic content (large `seq` loops), you can provide a hint in KB:

```nim
layout UserList(users: seq[string]) {.buf:32.}:   # 32 KB hint
  Ul:
    for user in users:
      Li: user
```

The actual capacity is `max(computed formula, hint × 1024)`.

### Zero-Copy Response Chain

The string created by a `{.buf.}` layout is never copied on its way to the client:

1. `newStringOfCap(N)` — one allocation, capacity pre-computed at compile time
2. `buf.add(...)` — writes fill the buffer, no reallocation if estimate is good
3. Layout returns `buf` — **moved**, not copied (ORC last-use optimization)
4. `answer(buf)` → `Response.body = buf` — **moved** into the Response object
5. HTTP server sends `Response.body` — reads bytes directly, no copy

Result: **1 allocation, 0 copies** for the entire render-to-response pipeline.

### Summary

| Feature | Regular `layout` | `layout {.buf.}` |
|---------|------------------|-----------------------|
| Buffer | Own buffer per layout | Shared with parent |
| Nesting | `raw Inner()` (copy) | `Inner()` (direct write) |
| Lazy params | Not supported | `content: lazyLayout` + `lazy content=expr` |
| Buffer sizing | `staticLen + 256` | `staticLen + dynamic*64 + nested + 256` |
| Hint override | No | `{.buf:N.}` (KB) |

## Full Example

```nim
import std/json
import starlight

# --- Shared buffer layouts ---
# All {.buf.} layouts write to a single buffer — zero intermediate allocations.

# Simple buffered component (no lazy params)
layout SiteNav() {.buf.}:
  Nav:
    A(href="/"): "Home"
    raw " | "
    A(href="/users"): "Users"

# Page shell with a lazy parameter for page content
layout Shell(pageTitle: string, content: lazyLayout) {.buf.}:
  Html:
    Head:
      Meta(charset="utf-8")
      Title: pageTitle
      Style: "body { font-family: system-ui; max-width: 800px; margin: 0 auto; padding: 20px; }"
    Body:
      SiteNav()        # {.buf.} → writes to the same buffer
      Hr
      content          # ← lazy param: called here, writes to buffer at this position

# Page content layouts
layout HomeContent() {.buf.}:
  H1: "Welcome"
  P: "A super fast SSR framework for Nim."

layout UsersContent(users: seq[string]) {.buf.}:
  H1: "Users"
  Ul:
    for user in users:
      Li:
        A(href="/users/" & user): user

layout UserProfileContent(name: string) {.buf.}:
  H1: name
  P: "Profile page"
  A(href="/users"): "Back"

# Pages pass content to Shell via lazy
layout HomePage(pageTitle: string) {.buf.}:
  Shell(pageTitle=pageTitle, lazy content=HomeContent())

layout UsersPage(pageTitle: string, users: seq[string]) {.buf.}:
  Shell(pageTitle=pageTitle, lazy content=UsersContent(users=users))

layout UserProfilePage(pageTitle: string, name: string) {.buf.}:
  Shell(pageTitle=pageTitle, lazy content=UserProfileContent(name=name))

# --- Handlers ---
# Handler calls a {.buf.} layout → one allocation, zero copies.
# The buffer is created once, filled by all nested layouts, then moved into Response.body.

handler listUsers() {.html.}:
  let users = @["Alice", "Bob", "Charlie"]
  return UsersPage(pageTitle="Users", users=users)

handler getUser(name: string) {.html.}:
  return UserProfilePage(pageTitle=name, name=name)

handler getStatus() {.json.}:
  return %*{"status": "ok"}

handler home() {.html.}:
  return HomePage(pageTitle="Home")

# --- Routes ---

route UsersApi:
  get("", listUsers)
  get("/{name}", getUser)

route ApiRoutes:
  get("/status", getStatus)

route MainRoute:
  get("", home)

# --- Middleware ---

proc logger(ctx: Context, next: HandlerProc): Future[Response] {.
    async: (raises: [CatchableError]), gcsafe.} =
  echo ctx.httpMethod, " ", ctx.path
  result = await next(ctx)

# --- Router ---

var router = newRouter()
router.use(logger)
router.mount("/users", UsersApi)
router.mount("/api", ApiRoutes)
router.mount("/", MainRoute)
router.serve("127.0.0.1", 5000)
```

In this example, every HTML page shares the same `Shell` layout via `lazy content=`. When a handler calls `HomePage(pageTitle="Home")`:

1. One buffer is created with compile-time estimated capacity
2. `Shell` writes `<html><head>...</head><body>`, then `SiteNav()` writes `<nav>...</nav>` to the **same buffer**
3. The `content` lazy param is called — `HomeContent()` writes to the same buffer at the correct position
4. `Shell` finishes writing the closing tags
5. The completed string is **moved** (not copied) into `Response.body` via ORC move semantics
6. Result: **1 allocation, 0 copies** for the entire page

## API Reference

| Symbol | Kind | Description |
|--------|------|-------------|
| `layout Name(params):` | macro | Defines a reusable HTML layout |
| `layout Name(params) {.buf.}:` | macro | Layout that writes to a shared buffer |
| `layout Name(params) {.buf:N.}:` | macro | Shared buffer layout with N KB capacity hint |
| `handler Name(params) {.html.}:` | macro | Handler that wraps return in `answer()` (text/html) |
| `handler Name(params) {.json.}:` | macro | Handler that wraps return in `answerJson()` (application/json) |
| `handler Name(params):` | macro | Raw handler, return must be a `Response` |
| `withTimeout(ms)` | proc | Middleware: aborts handler after `ms` milliseconds (Http408) |
| `route Name:` | macro | Defines a route group |
| `newRouter()` | proc | Creates a new router |
| `router.mount(prefix, group)` | proc | Mounts a route group at prefix |
| `router.use(middleware)` | proc | Adds global middleware |
| `router.serve(host, port)` | proc | Starts the HTTP server |
| `ctx.forward(method, path)` | proc | Internal dispatch through the router (supports relative paths) |
| `answer(body, code)` | proc | Builds an HTML Response |
| `answerJson(body, code)` | proc | Builds a JSON Response (accepts string or JsonNode) |
| `redirect(url, code)` | proc | Builds a redirect Response (302, client-side) |
| `ctx.path` | field | Request path (per-dispatch, copied on forward) |
| `ctx.httpMethod` | field | HTTP method (per-dispatch, copied on forward) |
| `ctx.pathParams` | field | Path parameters (per-dispatch, new on forward) |
| `ctx.request.body` | field | Request body |
| `ctx.request.headers` | field | Request headers |
| `ctx.request.query` | field | Query parameters |
| `ctx.request.ip` | field | Client IP |
| `raw expr` | keyword | Insert content without escaping (inside layout) |
| `escapeHtml(s)` | proc | HTML-escape a string (`&` → `&amp;`, `<` → `&lt;`, etc.) |
| `content: lazyLayout` | param type | Deferred parameter — evaluated at usage position in buffer |
| `lazy content=expr` | keyword | Pass `expr` as a lazy parameter (wrapped in nimcall proc) |

## License

MIT
