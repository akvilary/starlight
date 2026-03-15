# Starlight

Super fast server-side rendering framework for Nim.

Starlight combines the stability of Prologue with the ergonomics of HappyX, while adding compile-time HTML optimization that makes it the fastest SSR framework in the Nim ecosystem.

## Features

- **Built on [Chronos](https://github.com/status-im/nim-chronos)** — async engine and HTTP server from the Status team, battle-tested in production.
- **Compile-time HTML optimization** — static parts of templates are pre-computed and baked into the binary. Only dynamic expressions are evaluated at runtime.
- **Native Nim syntax in HTML DSL** — no special syntax like `{var}` or `x->inc()`. Just write normal Nim code inside `layout` blocks.
- **PrefixTree router** — typed path parameters (`{id:int}`, `{slug}`, `{price:float}`) with compile-time validation.
- **Middleware chain** — explicit `next` callback pattern for predictable request processing.
- **Zero-overhead layouts** — `layout` generates inline procs with implicit context passing.
- **Single allocation rendering** — the HTML engine pre-calculates buffer size and builds the entire page in one string.
- **Shared buffer mode (`{.toBuffer.}`)** — nested layouts write to a single shared buffer with zero intermediate allocations. Buffer capacity is computed at compile time. The final string is moved (not copied) through the entire response chain thanks to Nim's ORC move semantics.

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
  html:
    head:
      title: "Hello Starlight"
    body:
      h1: "It works!"

responseHtml home():
  return HomePage()

route Main:
  get("", home)

var app = newApp()
app.mount("/", Main)
app.serve("127.0.0.1", 5000)
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
  tdiv(class="card"):
    h2(class="card-title"): title
    p(class="card-body"): body
    if footer != "":
      tdiv(class="card-footer"): footer
```

### Nested Layouts

Layouts can call other layouts using `raw`:

```nim
layout Nav():
  nav:
    a(href="/"): "Home"
    text " | "
    a(href="/about"): "About"

layout Page(pageTitle: string, content: string):
  html:
    head:
      meta(charset="utf-8")
      title: pageTitle
    body:
      raw Nav()
      hr
      main:
        raw content
```

### Using Layouts in Handlers

Layouts are called like regular functions. `ctx` is passed implicitly:

```nim
responseHtml home():
  return Page(pageTitle="Home", content=Card(title="Welcome", body="Hello!"))
```

### HTML Tags

Tags are recognized from a built-in set of HTML tag names. Attributes are passed as named parameters. Void tags (`br`, `hr`, `img`, `input`, etc.) self-close automatically.

```nim
layout MyPage():
  h1: "Hello World"
  p: "A paragraph"
  a(href="/about"): "About"
  img(src="/logo.png", alt="Logo")
  br
```

### Dynamic Content

Variables and expressions work as normal Nim code. All dynamic content is automatically HTML-escaped:

```nim
layout Greeting(userName: string, messageCount: int):
  h1: "Hello, " & userName & "!"
  p: "You have " & $messageCount & " messages"
```

### Control Flow

Standard Nim control flow works inside layouts:

```nim
layout UserNav(loggedIn: bool, userName: string):
  if loggedIn:
    p: "Welcome back, " & userName
    a(href="/logout"): "Logout"
  else:
    a(href="/login"): "Login"

layout ItemList(items: seq[string]):
  ul:
    for item in items:
      li: item
```

### Raw HTML and Text

Use `raw` to insert pre-rendered HTML without escaping, and `text` to insert escaped text alongside tags:

```nim
layout Article(content: string, author: string):
  tdiv(class="article"):
    raw content
  p:
    text "Written by "
    strong: author
```

### Nim Keyword Conflicts

Some HTML tags conflict with Nim keywords. Use prefixed aliases:

| HTML tag    | Nim alias    |
|-------------|-------------|
| `div`       | `tdiv`      |
| `template`  | `ttemplate` |
| `object`    | `tobject`   |
| `var`       | `tvar`      |

## Handlers

Three macros generate async handler procs:

- `responseHtml` — wraps `return` expressions in `answer()` (Content-Type: text/html)
- `responseJson` — wraps `return` expressions in `answerJson()` (Content-Type: application/json)
- `response` — no wrapping, `return` must provide a `Response` directly

If no `return` is specified, the handler returns `Http200` with an empty body.

### HTML Handler

```nim
# With macro:
responseHtml home():
  return Page(pageTitle="Home", content=HomePage())

# Without macro (equivalent):
proc home(ctx: Context): Future[Response] {.async, gcsafe.} =
  return answer(Page(pageTitle="Home", content=HomePage()))
```

### JSON Handler

```nim
# With macro:
responseJson getStatus():
  return %*{"status": "ok", "version": "0.1.0"}

# Without macro (equivalent):
proc getStatus(ctx: Context): Future[Response] {.async, gcsafe.} =
  return answerJson(%*{"status": "ok", "version": "0.1.0"})
```

### Custom HTTP Status Code

To return a response with a custom status code, use a tuple `(body, HttpCode)`:

```nim
responseJson unauthorized():
  return (%*{"error": "not authorized"}, Http401)

responseHtml notFound():
  return (Page(title="404", content=NotFound()), Http404)
```

### Raw Response Handler

```nim
response customHandler():
  return answer("plain text", Http200)
```

### Default Response

If no `return` is specified, the handler returns `Http200` with an empty body (`""`):

```nim
response fireAndForget():
  echo "doing work, no return"
  # return "" # Http200
```

### JSON from Pre-Serialized String

`answerJson` accepts both `JsonNode` (serializes automatically) and `string` (sends as-is). This is useful when you have cached or pre-built JSON:

```nim
# JsonNode — serialized by the framework:
responseJson getStatus():
  return %*{"status": "ok"}

# Pre-serialized string — zero serialization overhead:
responseJson getCached():
  return cachedJsonString

# Without macro:
proc getCached(ctx: Context): Future[Response] {.async, gcsafe.} =
  return answerJson(cachedJsonString)
```

### Path Parameters

Path parameters are declared in the handler signature with their types. They are automatically extracted from `ctx.pathParams` and converted to the specified type:

```nim
# Route: get("/{name}", getUser)
responseHtml getUser(name: string):
  # name is automatically bound from ctx.pathParams["name"]
  return Page(pageTitle=name, content=UserProfile(name=name))

# Route: get("/{id:int}", getItem)
responseJson getItem(id: int):
  # id is automatically parsed as int from ctx.pathParams["id"]
  let item = fetchItem(id)
  return %*{"id": id, "name": item.name}
```

### Accessing Request Context

The `ctx` object is available in every handler:

```nim
responseJson search():
  let query = ctx.getQuery("q")
  let token = ctx.headers["Authorization"]
  let data = parseJson(ctx.body)
  return %*{"query": query, "ip": ctx.ip}
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

Mount route groups on the app with a prefix:

```nim
var app = newApp()
app.mount("/users", UsersApi)
app.mount("/api", ApiRoutes)
app.mount("/", Pages)
app.serve("127.0.0.1", 5000)
```

Routes are combined: a `get "/{id}"` inside `UsersApi` mounted at `/users` becomes `GET /users/{id}`.

## Middleware

Middleware functions wrap handlers with a `next` callback:

```nim
proc loggingMiddleware(ctx: Context, next: HandlerProc): Future[Response] {.async.} =
  echo ctx.httpMethod, " ", ctx.path
  result = await next(ctx)

proc authMiddleware(ctx: Context, next: HandlerProc): Future[Response] {.async.} =
  if ctx.headers.hasKey("Authorization"):
    result = await next(ctx)
  else:
    result = answerJson(%*{"error": "Unauthorized"}, Http401)
```

Register middleware globally:

```nim
var app = newApp()
app.use(loggingMiddleware)
app.use(authMiddleware)
```

Execution order: middlewares run in registration order. Each middleware can choose to call `next` (continue) or not (stop the chain).

## Compile-Time Optimization

Starlight's key advantage: the HTML engine analyzes templates at compile time and separates static from dynamic parts.

```nim
layout MyPage(userName: string, bio: string):
  head:
    title: "My App"
    meta(charset="utf-8")
  body:
    h1: userName
    p: bio
```

Generated code (conceptually):

```nim
var buf = newStringOfCap(256)
buf.add "<head><title>My App</title><meta charset=\"utf-8\"/></head><body><h1>"
buf.add escapeHtml($userName)   # only runtime work
buf.add "</h1><p>"
buf.add escapeHtml($bio)        # only runtime work
buf.add "</p></body>"
```

On a typical page where 80-90% is static markup, this means near-zero runtime overhead.

## Shared Buffer Mode

By default, each `layout` creates its own string buffer, fills it, and returns the result. When layouts are nested via `raw`, the inner layout allocates a separate buffer, returns it as a string, and the outer layout copies it in. For a page with 5 nested components, that means 5 allocations + 4 copies.

The `{.toBuffer.}` pragma eliminates this overhead. All nested `{.toBuffer.}` layouts write to **one shared buffer** — zero intermediate allocations.

### How It Works

Add `{.toBuffer.}` to any layout:

```nim
layout Header() {.toBuffer.}:
  header:
    h1: "My Site"

layout Page(title: string, content: string) {.toBuffer.}:
  html:
    head:
      title: title
    body:
      Header()       # {.toBuffer.} → writes to the same buffer, no allocation
      raw content    # regular layout → returns string, added to buffer
```

A `{.toBuffer.}` layout automatically detects its calling context:
- **Called from a handler** — creates a buffer, fills it, returns the string. Nim's ARC moves it into `Response.body` with zero copies.
- **Called inside another layout** — detects the parent's buffer and writes to it directly. No allocation, no copy.

Regular layouts (without `{.toBuffer.}`) always return strings. Use `raw` to embed them inside other layouts, as before.

### Container Slots

For page wrappers that need to accept arbitrary content, use `container` to define a slot and `containered` to fill it:

```nim
layout Shell(title: string) {.toBuffer.}:
  html:
    head:
      title: title
      style: "body { font-family: system-ui; }"
    body:
      container    # ← slot: caller's content is injected here
      footer:
        p: "Powered by Starlight"

layout HomePage(title: string) {.toBuffer.}:
  containered Shell(title=title):   # fill Shell's container slot
    Header()                         # {.toBuffer.} → shared buffer
    main:
      h1: "Welcome"
      p: "Fast SSR for Nim."
```

Everything — Shell's markup, Header's content, the main section — writes to a single buffer. The `containered` keyword processes the body block through the HTML DSL and injects it at the `container` position.

### Buffer Capacity

Each `{.toBuffer.}` layout exports a compile-time constant `Name_staticCap` computed from:

| Component | Source |
|-----------|--------|
| Static HTML bytes | Counted from string literals in generated code |
| Dynamic expressions | Number of runtime values × 64 bytes each |
| Nested `{.toBuffer.}` layouts | Sum of their `_staticCap` constants |
| Margin | +256 bytes |

The top-level layout uses this constant for `newStringOfCap`. If the page exceeds the estimate (e.g. a large dynamic list), Nim's string auto-grows (2x doubling, amortized O(1)).

For layouts with unpredictable dynamic content (large `seq` loops), you can provide a hint in KB:

```nim
layout UserList(users: seq[string]) {.toBuffer: 32.}:   # 32 KB hint
  ul:
    for user in users:
      li: user
```

The actual capacity is `max(computed formula, hint × 1024)`.

### Zero-Copy Response Chain

The string created by a `{.toBuffer.}` layout is never copied on its way to the client:

1. `newStringOfCap(N)` — one allocation, capacity pre-computed at compile time
2. `buf.add(...)` — writes fill the buffer, no reallocation if estimate is good
3. Layout returns `buf` — **moved**, not copied (ORC last-use optimization)
4. `answer(buf)` → `Response.body = buf` — **moved** into the Response object
5. HTTP server sends `Response.body` — reads bytes directly, no copy

Result: **1 allocation, 0 copies** for the entire render-to-response pipeline.

### Summary

| Feature | Regular `layout` | `layout {.toBuffer.}` |
|---------|------------------|-----------------------|
| Buffer | Own buffer per layout | Shared with parent |
| Nesting | `raw Inner()` (copy) | `Inner()` (direct write) |
| Slots | Not supported | `container` / `containered` |
| Buffer sizing | `staticLen + 256` | `staticLen + dynamic*64 + nested + 256` |
| Hint override | No | `{.toBuffer: N.}` (KB) |

## Full Example

```nim
import std/json
import starlight

# --- Layouts ---

layout Page(pageTitle: string, content: string):
  html:
    head:
      meta(charset="utf-8")
      title: pageTitle
      style: "body { font-family: system-ui; max-width: 800px; margin: 0 auto; padding: 20px; }"
    body:
      nav:
        a(href="/"): "Home"
        text " | "
        a(href="/users"): "Users"
      hr
      raw content

layout UserList(users: seq[string]):
  h1: "Users"
  ul:
    for user in users:
      li:
        a(href="/users/" & user): user

layout UserProfile(name: string):
  h1: name
  p: "Profile page"
  a(href="/users"): "Back"

layout HomePage():
  h1: "Welcome"
  p: "A super fast SSR framework for Nim."

# --- Handlers ---

responseHtml listUsers():
  let users = @["Alice", "Bob", "Charlie"]
  return Page(pageTitle="Users", content=UserList(users=users))

responseHtml getUser(name: string):
  return Page(pageTitle=name, content=UserProfile(name=name))

responseJson getStatus():
  return %*{"status": "ok"}

responseHtml home():
  return Page(pageTitle="Home", content=HomePage())

# --- Routes ---

route UsersApi:
  get("", listUsers)
  get("/{name}", getUser)

route ApiRoutes:
  get("/status", getStatus)

route Main:
  get("", home)

# --- Middleware ---

proc logger(ctx: Context, next: HandlerProc): Future[Response] {.async.} =
  echo ctx.httpMethod, " ", ctx.path
  result = await next(ctx)

# --- App ---

var app = newApp()
app.use(logger)
app.mount("/users", UsersApi)
app.mount("/api", ApiRoutes)
app.mount("/", Main)
app.serve("127.0.0.1", 5000)
```

## API Reference

| Symbol | Kind | Description |
|--------|------|-------------|
| `layout Name(params):` | macro | Defines a reusable HTML layout |
| `layout Name(params) {.toBuffer.}:` | macro | Layout that writes to a shared buffer |
| `layout Name(params) {.toBuffer: N.}:` | macro | Shared buffer layout with N KB capacity hint |
| `responseHtml Name(params):` | macro | Defines an HTML handler (wraps return in `answer()`) |
| `responseJson Name(params):` | macro | Defines a JSON handler (wraps return in `answerJson()`) |
| `response Name(params):` | macro | Defines a raw handler (return must be `Response`) |
| `route Name:` | macro | Defines a route group |
| `newApp()` | proc | Creates a new application |
| `app.mount(prefix, group)` | proc | Mounts a route group at prefix |
| `app.use(middleware)` | proc | Adds global middleware |
| `app.serve(host, port)` | proc | Starts the HTTP server |
| `answer(body, code)` | proc | Builds an HTML Response |
| `answerJson(body, code)` | proc | Builds a JSON Response (accepts string or JsonNode) |
| `redirect(url, code)` | proc | Builds a redirect Response |
| `ctx.body` | field | Request body |
| `ctx.headers` | field | Request headers |
| `ctx.query` | field | Query parameters |
| `ctx.pathParams` | field | Path parameters |
| `ctx.path` | field | Request path |
| `ctx.ip` | field | Client IP |
| `ctx.httpMethod` | field | HTTP method |
| `raw expr` | keyword | Insert HTML without escaping (inside layout) |
| `text expr` | keyword | Insert text with escaping (inside layout) |
| `container` | keyword | Define a slot inside `{.toBuffer.}` layout |
| `containered Name(args): body` | keyword | Call a `{.toBuffer.}` layout and fill its `container` slot |

## License

MIT
