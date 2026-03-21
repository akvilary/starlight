# Starlight

Super fast server-side rendering framework for Nim.

Starlight combines the stability of Prologue with the ergonomics of HappyX, while adding compile-time HTML optimization that makes it the fastest SSR framework in the Nim ecosystem.

## Table of Contents

- [Features](#features)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Layouts](#layouts)
  - [Basic Layout](#basic-layout)
  - [Nested Layouts](#nested-layouts)
  - [Using Third-Party Template Engines](#using-third-party-template-engines)
  - [Using Layouts in Handlers](#using-layouts-in-handlers)
  - [HTML Tags](#html-tags)
  - [Dynamic Content](#dynamic-content)
  - [Control Flow](#control-flow)
  - [Raw HTML and Escaping](#raw-html-and-escaping)
- [Handlers](#handlers)
  - [HTML Handler](#html-handler)
  - [JSON Handler](#json-handler)
  - [Custom HTTP Status Code](#custom-http-status-code)
  - [Raw Response Handler](#raw-response-handler)
  - [Default Response](#default-response)
  - [JSON from Pre-Serialized String](#json-from-pre-serialized-string)
  - [Path Parameters](#path-parameters)
  - [Query Parameters](#query-parameters-1)
  - [Accessing Request Context](#accessing-request-context)
- [Routing](#routing)
  - [Route Groups](#route-groups)
  - [Per-Route Middleware](#per-route-middleware)
  - [Path Parameters](#path-parameters-1)
- [Route Entities](#route-entities)
  - [Creating a Route Entity](#creating-a-route-entity)
  - [Registering Route Entities](#registering-route-entities)
  - [Route Entities with Middleware](#route-entities-with-middleware)
- [URL Builder](#url-builder)
  - [urlAs — URL from Pattern](#urlas--url-from-pattern)
  - [urlFor — URL from Route Entity](#urlfor--url-from-route-entity)
  - [Relative URLs](#relative-urls)
  - [Query Parameters](#query-parameters)
  - [External URLs](#external-urls)
- [Middleware](#middleware)
  - [Middleware Macro](#middleware-macro)
  - [Built-in Middleware](#built-in-middleware)
  - [Writing Custom Middleware](#writing-custom-middleware)
- [Internal Dispatch](#internal-dispatch)
  - [Custom Query Parameters](#custom-query-parameters)
  - [Absolute and Relative Paths](#absolute-and-relative-paths)
  - [Forward vs Redirect](#forward-vs-redirect)
- [Static Files & CDN Proxy](#static-files--cdn-proxy)
  - [Local Directory](#local-directory)
  - [Local File](#local-file)
  - [Extension Filter](#extension-filter)
  - [CDN Proxy](#cdn-proxy)
  - [Resolution Order](#resolution-order)
  - [Security](#security)
- [Custom Error Pages](#custom-error-pages)
- [Form Parsing](#form-parsing)
  - [URL-Encoded Forms](#url-encoded-forms)
  - [File Uploads (Multipart)](#file-uploads-multipart)
  - [FormData Accessors](#formdata-accessors)
- [Cookies](#cookies)
  - [Reading Cookies](#reading-cookies)
  - [Setting Cookies](#setting-cookies)
  - [Deleting Cookies](#deleting-cookies)
  - [Cookie Options](#cookie-options)
- [Compile-Time Optimization](#compile-time-optimization)
- [Shared Buffer Mode](#shared-buffer-mode)
  - [How It Works](#how-it-works)
  - [Lazy Parameters](#lazy-parameters)
  - [Buffer Capacity](#buffer-capacity)
  - [Zero-Copy Response Chain](#zero-copy-response-chain)
  - [Summary](#summary)
- [Full Example](#full-example)
- [API Reference](#api-reference)
- [License](#license)

## Features

- **Built on [Chronos](https://github.com/status-im/nim-chronos)** — async engine and HTTP server from the Status team, battle-tested in production.
- **Compile-time HTML optimization** — static parts of templates are pre-computed and baked into the binary. Only dynamic expressions are evaluated at runtime.
- **Native Nim syntax in HTML DSL** — no special syntax like `{var}` or `x->inc()`. Just write normal Nim code inside `layout` blocks.
- **PrefixTree router** — typed path parameters (`{id:int}`, `{slug}`, `{price:float}`) and typed query parameters (`page = 1`, `q: string`) with compile-time validation.
- **Route entities** — bundle handler + pattern + middleware into a reusable `RouteRef`. Register once, generate type-safe URLs with `urlFor`.
- **Compile-time URL builder** — `urlAs` and `urlFor` macros validate parameters at compile time. Supports relative URLs (`RelRef`) for mounted route groups.
- **Middleware chain** — explicit `next` callback pattern for predictable handler processing.
- **Zero-overhead layouts** — `layout` generates inline procs for HTML rendering.
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

handler home(ctx: Context) {.html.}:
  return HomePage()

route Main:
  get("./", home)

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

`layout` creates reusable HTML templates. HTML tags are only available inside `layout` bodies. Layouts are pure rendering functions — pass any needed data explicitly via parameters.

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

Layouts are called like regular functions:

```nim
handler home(ctx: Context) {.html.}:
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

The `handler` macro generates a typed async proc with real parameters:

```nim
# What you write:
handler getUser(ctx: Context, name: string) {.html.}:
  return UserProfile(name=name)

# What the macro generates:
proc getUser*(ctx: Context, name: string): Future[Response] {.
    async: (raises: [CatchableError]).} =
  return answer(UserProfile(name=name))
```

The macro generates exactly the parameters you declare. Handlers are ordinary functions you can call directly from code:

```nim
let resp = await getUser(ctx, "Alice")
```

The `route` macro uses compile-time reflection to generate a `HandlerProc` wrapper that extracts path params from `ctx.pathParams` and calls the typed handler. The handler itself knows nothing about routing.

Use pragmas to specify the response type:

- `{.html.}` — wraps `return` expressions in `answer()` (Content-Type: text/html)
- `{.json.}` — wraps `return` expressions in `answerJson()` (Content-Type: application/json)
- *(no pragma)* — no wrapping, `return` must provide a `Response` directly

If no `return` is specified, the handler returns `Http200` with an empty body.

### HTML Handler

```nim
handler home(ctx: Context) {.html.}:
  return Page(pageTitle="Home", content=HomePage())

# Equivalent to:
# proc home*(ctx: Context): Future[Response] {.async, gcsafe.} =
#   return answer(Page(pageTitle="Home", content=HomePage()))
```

### JSON Handler

```nim
handler getStatus(ctx: Context) {.json.}:
  return %*{"status": "ok", "version": "0.1.0"}

# Equivalent to:
# proc getStatus*(ctx: Context): Future[Response] {.async, gcsafe.} =
#   return answerJson(%*{"status": "ok", "version": "0.1.0"})
```

### Custom HTTP Status Code

To return a response with a custom status code, use a tuple `(body, HttpCode)`:

```nim
handler unauthorized(ctx: Context) {.json.}:
  return (%*{"error": "not authorized"}, Http401)

handler notFound(ctx: Context) {.html.}:
  return (Page(title="404", content=NotFound()), Http404)
```

### Raw Response Handler

```nim
handler customHandler(ctx: Context):
  return answer("plain text", Http200)
```

### Default Response

If no `return` is specified, the handler returns `Http200` with an empty body (`""`):

```nim
handler fireAndForget(ctx: Context):
  echo "doing work, no return"
  # return "" # Http200
```

### JSON from Pre-Serialized String

`answerJson` accepts both `JsonNode` (serializes automatically) and `string` (sends as-is). This is useful when you have cached or pre-built JSON:

```nim
# JsonNode — serialized by the framework:
handler getStatus(ctx: Context) {.json.}:
  return %*{"status": "ok"}

# Pre-serialized string — zero serialization overhead:
handler getCached(ctx: Context) {.json.}:
  return cachedJsonString

# Without macro:
proc getCached(ctx: Context): Future[Response] {.async, gcsafe.} =
  return answerJson(cachedJsonString)
```

### Path Parameters

Declare path parameters as typed proc parameters. The type in the handler must match the type in the route pattern:

```nim
handler getUser(ctx: Context, name: string) {.html.}:
  return Page(pageTitle=name, content=UserProfile(name=name))

handler getItem(ctx: Context, id: int) {.json.}:
  let item = fetchItem(id)
  return %*{"id": id, "name": item.name}
```

When the route is registered (via the `route` macro), the pattern determines type conversion:

| Pattern syntax  | Handler param | Conversion at routing |
|-----------------|---------------|-----------------------|
| `{name}`        | `name: string` | `ctx.pathParams["name"]` |
| `{id:int}`      | `id: int`     | `parseInt(ctx.pathParams["id"])` |
| `{price:float}` | `price: float` | `parseFloat(ctx.pathParams["price"])` |
| `{active:bool}` | `active: bool` | `parseBool(ctx.pathParams["active"])` |

Type validation happens during route matching — if `{id:int}` receives a non-numeric value, the route won't match (404).

### Query Parameters

Handler parameters that don't match any path parameter in the route pattern are automatically parsed from the query string. Use `= defaultValue` to make a parameter optional — its type is inferred from the literal:

```nim
handler search(ctx: Context, q: string, page = 1, sort = "date") {.json.}:
  return %*{"q": q, "page": page, "sort": sort}

route Api:
  get("./search", search)

router.mount("/api", Api)
# GET /api/search?q=nim&page=2 → {"q":"nim","page":2,"sort":"date"}
```

**How it works:**

The `route` macro inspects the handler's parameters at compile time. Parameters matching `{placeholders}` in the route pattern become path params; the rest become query params. A wrapper proc is generated that extracts values from `ctx.request.query`, converts types, and calls the handler — zero runtime reflection.

**Required vs optional:**

| Declaration     | Behavior |
|-----------------|----------|
| `q: string`     | Required — returns `400` if missing |
| `id: int`       | Required — returns `400` if missing or not a valid int |
| `page = 1`      | Optional — defaults to `1` if missing, `400` if present but not a valid int |
| `sort = "date"` | Optional — defaults to `"date"` if missing |
| `active = false`| Optional — defaults to `false` if missing |
| `amount = 0.0`  | Optional — defaults to `0.0` if missing |

Supported types: `string`, `int`, `float`, `bool`.

**Mixing path and query parameters:**

```nim
handler userPosts(ctx: Context, name: string, page = 1) {.json.}:
  return %*{"user": name, "page": page}

route Users:
  get("./{name}/posts", userPosts)

router.mount("/users", Users)
# GET /users/alice/posts?page=3 → {"user":"alice","page":3}
```

Here `name` matches `{name}` in the pattern → path param. `page` has no matching placeholder → query param.

### Accessing Request Context

The `ctx` object gives direct access to headers, body, and other request data. For query parameters, prefer [typed query parameters](#query-parameters-1) — use `ctx.getQuery` only when you need dynamic key access:

```nim
handler info(ctx: Context) {.json.}:
  let token = ctx.request.headers["Authorization"]
  let data = parseJson(ctx.request.body)
  let custom = ctx.getQuery("key", "fallback") # dynamic key access
  return %*{"ip": ctx.request.ip, "custom": custom}
```

## Routing

Routes connect URL patterns to handlers via route groups.

### Route Groups

Define route groups with the `route` macro:

```nim
route UsersApi:
  get("./", listUsers)
  get("./{name}", getUser)
  post("./", createUser)

route ApiRoutes:
  get("./status", getStatus)
  post("./echo", echoBody)
  get("./health"):
    return answer("OK")
```

Mount groups on the router with a prefix:

```nim
var router = newRouter()
router.mount("/users", UsersApi)
router.mount("/api", ApiRoutes)
router.serve("127.0.0.1", 5000)
```

Routes are combined: `get("./{name}", getUser)` inside `UsersApi` mounted at `/users` becomes `GET /users/{name}`.

**All patterns in route groups must start with `"./"`.** This makes it explicit that patterns are relative to their mount prefix. A non-relative pattern will cause a compile-time error:

```nim
route Bad:
  get("/users", handler)    # ✗ compile error: must start with "./"
  get("./users", handler)   # ✓ correct
```

Use `"./"` for the root of a group (matches the mount prefix itself):

```nim
route UsersApi:
  get("./", listUsers)      # mounted at /users → matches /users
  get("./{name}", getUser)  # mounted at /users → matches /users/alice
```

### Per-Route Middleware

Attach middleware to individual routes:

```nim
route AdminApi:
  get("./", adminPanel, middleware = @[authMiddleware])
  get("./stats", adminStats, middleware = @[authMiddleware, adminOnly])
```

Middleware can also be applied to an entire group at mount time:

```nim
router.mount("/admin", AdminApi, middlewares = @[authMiddleware])
```

### Path Parameters

Path parameters are defined with `{name:type}` syntax:

| Syntax          | Nim type  | Example match    |
|-----------------|-----------|------------------|
| `{id:int}`      | `int`     | `/users/42`      |
| `{price:float}` | `float`   | `/items/9.99`    |
| `{active:bool}` | `bool`    | `/filter/true`   |
| `{slug}`        | `string`  | `/posts/my-post` |
| `{name:string}` | `string`  | `/users/alice`   |

Supported HTTP methods: `get`, `post`, `put`, `patch`, `delete`, `head`, `options`.

## Route Entities

A route entity (`RouteRef`) bundles a handler with its HTTP method, pattern, and optional middleware into a single reusable object. Define it once, register it anywhere, and generate type-safe URLs from it.

### Creating a Route Entity

```nim
handler getUser(ctx: Context, name: string) {.html.}:
  return UserProfile(name=name)

handler getPost(ctx: Context, id: int) {.json.}:
  return %*{"id": id}

# Create route entities with relative patterns (for use in route groups)
let userShow = newRoute(MethodGet, "./{name}", getUser)
let postShow = newRoute(MethodGet, "./{id:int}", getPost)
```

`newRoute` wraps the handler automatically — it extracts path parameters from `ctx.pathParams` and calls the typed handler with named arguments. You don't write any boilerplate.

When the pattern starts with `"./"`, `urlFor` returns relative URLs by default — no need to pass `RelRef`.

### Registering Route Entities

Use `add()` inside a `route` group or `router.addRoute()` directly:

```nim
# In a route group:
route Api:
  add(userShow)
  add(postShow)
  get("./health"):             # regular syntax works alongside add()
    return answer("OK")

router.mount("/users", Api)    # "./{name}" → /users/{name}
router.mount("/posts", Api)    # "./{id:int}" → /posts/{id:int}
```

### Route Entities with Middleware

Pass middleware when creating the route entity:

```nim
let protectedUser = newRoute(
  MethodGet,
  "./{name}",
  getUser,
  middleware = @[authMiddleware],
)

route Admin:
  add(protectedUser)
```

## URL Builder

Starlight provides two compile-time macros for building URLs with parameter validation. Missing parameters are caught at compile time.

### urlAs — URL from Pattern

Build a URL from a string pattern. Path parameters in `{braces}` are substituted from keyword arguments:

```nim
urlAs("/users/{name}", name = "alice")
# → "/users/alice"

urlAs("/posts/{id:int}", id = 42)
# → "/posts/42"
```

### urlFor — URL from Route Entity

Build a URL from a `RouteRef`. The pattern is extracted from the type at compile time. When the pattern starts with `"./"`, the URL is relative by default:

```nim
let userShow = newRoute(MethodGet, "./users/{name}", getUser)

urlFor(userShow, name = "alice")       # → "./users/alice"
```

Both `urlAs` and `urlFor` validate parameters at compile time. A missing parameter is a compile error:

```nim
urlFor(userShow)
# Error: urlFor: missing parameter 'name' required by "./users/{name}"
```

### Relative URLs

When a `RouteRef` pattern starts with `"./"`, `urlFor` returns a relative URL automatically — no need to pass `RelRef`.

Use `RelRef` to convert an absolute pattern to relative:

```nim
urlAs("/search", RelRef, q = "nim")           # → "./search?q=nim"
```

**Example with mount prefix:**

```nim
let userShow = newRoute(MethodGet, "./{name}", getUser)

route Api:
  add(userShow)   # pattern: "./{name}"

router.mount("/api/users", Api)  # full path: /api/users/{name}
```

In a layout rendered at `/api/dashboard`:

```nim
A(href = urlFor(userShow, name = "alice")):
  "Profile"
# href="./alice" → browser resolves to /api/users/alice
```

### Query Parameters

Keyword arguments that don't match any `{param}` in the pattern become URL-encoded query parameters:

```nim
urlAs("/search", q = "hello world", page = 1)
# → "/search?q=hello+world&page=1"

urlFor(userShow, name = "alice", tab = "posts")
# → "./alice?tab=posts"
```

### External URLs

Both `urlAs` and `urlFor` work with full external URLs:

```nim
urlAs("https://api.github.com/repos/{owner}/{repo}/issues",
  owner = "user", repo = "project", state = "open")
# → "https://api.github.com/repos/user/project/issues?state=open"
```

## Middleware

Middleware functions wrap handlers with a `next` callback.

### Middleware Macro

The `middleware` macro generates a typed async proc with the correct signature — no need to write `{.async: (raises: [CatchableError]).}` manually:

```nim
middleware logger(ctx: Context, next: HandlerProc):
  echo ctx.httpMethod, " ", ctx.path
  result = await next(ctx)

middleware auth(ctx: Context, next: HandlerProc):
  if ctx.request.headers.hasKey("Authorization"):
    result = await next(ctx)
  else:
    result = answerJson(%*{"error": "Unauthorized"}, Http401)
```

The macro generates a standard async proc with the correct signature:

```nim
# What you write:
middleware logger(ctx: Context, next: HandlerProc):
  echo ctx.httpMethod, " ", ctx.path
  result = await next(ctx)

# What the macro generates:
proc logger*(ctx: Context, next: HandlerProc): Future[Response] {.
    async: (raises: [CatchableError]), gcsafe.} =
  echo ctx.httpMethod, " ", ctx.path
  result = await next(ctx)
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
  get("./slow", slowHandler, middleware = @[withTimeout(3000)])
```

Internally, `withTimeout` calls Chronos `wait()` on the handler future and catches `AsyncTimeoutError`:

```nim
# What withTimeout(2000) does:
proc(ctx: Context, next: HandlerProc): Future[Response] {.
    async: (raises: [CatchableError]).} =
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

Note: You don't need to write `gcsafe` yourself — Nim infers it automatically. Just use `{.async: (raises: [CatchableError]).}`.

Example — response timing header:

```nim
proc withTiming(ctx: Context, next: HandlerProc): Future[Response] {.
    async: (raises: [CatchableError]).} =
  let start = Moment.now()
  result = await next(ctx)
  let elapsed = Moment.now() - start
  result.headers.add("X-Response-Time", $elapsed)
```

## Internal Dispatch

`ctx.forward` dispatches a request internally through the router. The client receives one response and never knows about the forward. All middleware of the target route is applied.

```nim
handler oldEndpoint(ctx: Context) {.json.}:
  return await ctx.forward(MethodGet, "/api/v2/data")
```

The router reference is stored in `ctx` automatically, so `forward` works from any handler without extra imports.

`forward` creates a lightweight clone of the context — only `path`, `httpMethod` and `pathParams` are new. Request data (headers, body, query, ip) is shared via a single `RequestData` ref, not copied.

### Custom Query Parameters

To forward with different query parameters, pass a `Table[string, string]`. This creates a new `RequestData` — the original context is not modified:

```nim
handler searchProxy(ctx: Context) {.json.}:
  return await ctx.forward(MethodGet, "/api/search", {"q": "nim", "page": "1"}.toTable())
```

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

## Static Files & CDN Proxy

`addCDN` serves static files from a local directory or proxies requests to a remote CDN. The path parameter is both the URL prefix and the filesystem directory (relative to CWD). Only `GET` requests are served. If no file is found, the request falls through to the normal 404 handler.

### Local Directory

```nim
var router = newRouter()
router.addCDN("/public")
router.serve("127.0.0.1", 5000)
# GET /public/style.css → ./public/style.css
# GET /public/js/app.js → ./public/js/app.js
```

### Local File

The path can point to a specific file instead of a directory:

```nim
router.addCDN("/robots.txt")
# GET /robots.txt → ./robots.txt
```

### Extension Filter

Restrict which file types are served (whitelist):

```nim
router.addCDN("/assets", extensions = @["css", "js", "png", "jpg", "svg", "woff2"])
# GET /assets/style.css  → served
# GET /assets/secret.env → rejected (not in extensions list)
```

Or block specific extensions (blacklist):

```nim
router.addCDN("/public", ignoreExtensions = @["env", "key", "pem"])
# GET /public/style.css  → served
# GET /public/secret.env → rejected
```

Both parameters can be combined — `extensions` is checked first (whitelist), then `ignoreExtensions` (blacklist).

### CDN Proxy

Proxy requests to a remote CDN. The `proxy` parameter specifies the remote base URL:

```nim
router.addCDN("/libs", proxy = "https://cdn.jsdelivr.net/npm")
# GET /libs/vue@3/dist/vue.js → proxies https://cdn.jsdelivr.net/npm/vue@3/dist/vue.js
```

A proxy can also point to a single file:

```nim
router.addCDN("/libs/vue.js", proxy = "https://cdn.jsdelivr.net/npm/vue@3/dist/vue.global.prod.js")
# GET /libs/vue.js → proxies the exact URL
```

Extension filtering (`extensions` and `ignoreExtensions`) works with proxy entries too:

```nim
router.addCDN("/libs", proxy = "https://cdn.jsdelivr.net/npm", extensions = @["js", "css"])
```

### Resolution Order

When a request doesn't match any route, the router tries CDN entries (GET only) in registration order. Each entry is either local or proxy — there is no fallback between them.

### Security

Local file serving includes path traversal protection:

- Paths containing `..` are rejected
- Resolved paths are verified to stay inside the served directory
- Only regular files are served (no directories, no symlinks escaping the root)

## Custom Error Pages

By default, Starlight returns plain-text responses for errors (`"Not Found"`, `"Internal Server Error"`). Use `router.onError` to register custom error handlers for any HTTP status code:

```nim
layout NotFoundPage(path: string) {.buf.}:
  Html:
    Body:
      H1: "404 — Page Not Found"
      P: "Nothing at " & path
      A(href="/"): "Go Home"

handler notFound(ctx: Context) {.html.}:
  return (NotFoundPage(path=ctx.path), Http404)

handler serverError(ctx: Context) {.html.}:
  return ("Something went wrong", Http500)

var router = newRouter()
router.onError(Http404, notFound)
router.onError(Http500, serverError)
```

Error handlers are regular `HandlerProc` — they receive the full `Context` (path, headers, query, etc.) and return a `Response`. Define them with the `handler` macro just like any other handler.

**How it works:**

- **404** — when no route matches and no CDN file is found, the custom 404 handler is called
- **500** — when a route handler throws an unhandled exception, the custom 500 handler is called
- **Any code** — `onError` accepts any `HttpCode`, so you can register handlers for 403, 408, etc.

**Safety:** if a custom error handler itself throws an exception, Starlight falls back to a plain-text response. Error handlers never cause cascading failures.

## Form Parsing

`ctx.formData()` parses the request body based on the `Content-Type` header. Supports `application/x-www-form-urlencoded` and `multipart/form-data`.

### URL-Encoded Forms

```nim
# POST /login
# Content-Type: application/x-www-form-urlencoded
# Body: username=alice&password=secret

handler login(ctx: Context) {.json.}:
  let form = ctx.formData()
  let username = form["username"]       # "alice"
  let password = form["password"]       # "secret"
  return %*{"user": username}
```

### File Uploads (Multipart)

```nim
# POST /upload
# Content-Type: multipart/form-data; boundary=...

handler upload(ctx: Context) {.json.}:
  let form = ctx.formData()
  let title = form["title"]             # text field
  let file = form.file("avatar")        # uploaded file
  echo file.filename                    # "photo.jpg"
  echo file.contentType                 # "image/jpeg"
  echo file.data.len                    # size in bytes
  return %*{"uploaded": file.filename, "size": file.data.len}
```

`UploadFile` fields:

| Field | Type | Description |
|-------|------|-------------|
| `filename` | `string` | Original filename from the client |
| `contentType` | `string` | Content-Type from the part header |
| `data` | `seq[byte]` | File content as raw bytes |

### FormData Accessors

| Accessor | Returns | On missing key |
|----------|---------|----------------|
| `form["key"]` | `string` | Raises `KeyError` |
| `form.getField("key", "default")` | `string` | Returns default |
| `form.file("key")` | `UploadFile` | Raises `KeyError` |
| `form.hasField("key")` | `bool` | `false` |
| `form.hasFile("key")` | `bool` | `false` |

If the `Content-Type` header is missing or unsupported (e.g., `application/json`), `formData()` returns an empty `FormData` with no fields or files.

## Cookies

### Reading Cookies

Use `ctx.cookies.get` to read cookies from the request. Parsing is lazy — the Cookie header is only parsed on the first call, then all subsequent lookups are O(1) table access:

```nim
handler dashboard(ctx: Context) {.html.}:
  let theme = ctx.cookies.get("theme", "light")
  let lang = ctx.cookies.get("lang", "en")
  return Dashboard(theme=theme, lang=lang)
```

### Setting Cookies

**In handlers** — use `ctx.cookies.set` to queue a `Set-Cookie` header for the outgoing response. The cookies are not sent immediately — they are collected and automatically added to the response by the router after the handler returns:

```nim
handler login(ctx: Context) {.html.}:
  ctx.cookies.set("session", token, httpOnly=true, secure=true, sameSite=Lax)
  ctx.cookies.set("theme", "dark")
  return "Welcome"
```

**In middleware or raw handlers** — use `response.withCookie` for a functional style (returns a new Response):

```nim
handler login(ctx: Context):
  return answer("Welcome")
    .withCookie("session", token, httpOnly=true, secure=true, sameSite=Lax)
    .withCookie("theme", "dark")
```

The value parameter is generic — any type with `$` works:

```nim
ctx.cookies.set("count", 42)
ctx.cookies.set("active", true)
```

### Deleting Cookies

`ctx.cookies.delete` sends a `Set-Cookie` header with `Max-Age=0` in the outgoing response, instructing the browser to remove the cookie:

```nim
# In a handler:
handler logout(ctx: Context) {.html.}:
  ctx.cookies.delete("session", path="/")
  return "Bye"

# Or on a response:
handler logout(ctx: Context):
  return answer("Bye").deleteCookie("session", path="/")
```

### Cookie Options

| Option | Type | Default | Purpose |
|--------|------|---------|---------|
| `path` | `string` | `""` (not set) | Cookie scope path |
| `domain` | `string` | `""` (not set) | Cookie scope domain |
| `maxAge` | `Option[int]` | `none(int)` (not set) | Lifetime in seconds |
| `expires` | `string` | `""` (not set) | Expiration date |
| `httpOnly` | `bool` | `false` | Invisible to JavaScript (XSS protection) |
| `secure` | `bool` | `false` | HTTPS only (MITM protection) |
| `sameSite` | `SameSite` | `Default` (not set) | CSRF protection: `Lax`, `Strict`, `None` |

Minimal call — only key and value are required, everything else is optional:

```nim
ctx.setCookie("theme", "dark")
# Set-Cookie: theme=dark
```

For session cookies, always use `httpOnly=true, secure=true, sameSite=Lax`.

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
handler home(ctx: Context) {.html.}:
  return Page(title="Hello")

# What actually happens:
#   1. Page template sees declared(buf) = false
#   2. Creates: var buf = newStringOfCap(Page_staticCap)
#   3. Calls __layout__Page(buf, title) — fills buf
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
                      # → calls __layout__SiteHeader(buf) directly
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
        A(href=urlAs("/users/{name}", name=user)): user

layout UserProfileContent(name: string) {.buf.}:
  H1: name
  P: "Profile page"
  A(href=urlAs("/users")): "Back"

# Pages pass content to Shell via lazy
layout HomePage(pageTitle: string) {.buf.}:
  Shell(pageTitle=pageTitle, lazy content=HomeContent())

layout UsersPage(pageTitle: string, users: seq[string]) {.buf.}:
  Shell(pageTitle=pageTitle, lazy content=UsersContent(users=users))

layout UserProfilePage(pageTitle: string, name: string) {.buf.}:
  Shell(pageTitle=pageTitle, lazy content=UserProfileContent(name=name))

# --- Handlers ---
# Each handler is a typed proc with real parameters.
# Direct call: await getUser(ctx, "Alice")

handler listUsers(ctx: Context) {.html.}:
  let users = @["Alice", "Bob", "Charlie"]
  return UsersPage(pageTitle="Users", users=users)

handler getUser(ctx: Context, name: string) {.html.}:
  return UserProfilePage(pageTitle=name, name=name)

handler getStatus(ctx: Context) {.json.}:
  return %*{"status": "ok"}

handler home(ctx: Context) {.html.}:
  return HomePage(pageTitle="Home")

# --- Error pages ---

layout NotFoundContent(path: string) {.buf.}:
  H1: "404 — Not Found"
  P: "Nothing at " & path
  A(href="/"): "Go Home"

layout NotFoundPage(pageTitle: string, path: string) {.buf.}:
  Shell(pageTitle=pageTitle, lazy content=NotFoundContent(path=path))

handler notFound(ctx: Context) {.html.}:
  return (NotFoundPage(pageTitle="Not Found", path=ctx.path), Http404)

# --- Routes ---

route UsersApi:
  get("./", listUsers)
  get("./{name}", getUser)

route ApiRoutes:
  get("./status", getStatus)

route MainRoute:
  get("./", home)

# --- Middleware ---

middleware logger(ctx: Context, next: HandlerProc):
  echo ctx.httpMethod, " ", ctx.path
  result = await next(ctx)

# --- Router ---

var router = newRouter()
router.use(logger)
router.onError(Http404, notFound)
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
| `handler Name(params) {.html.}:` | macro | Generates typed async proc, wraps return in `answer()` (text/html) |
| `handler Name(params) {.json.}:` | macro | Generates typed async proc, wraps return in `answerJson()` (application/json) |
| `handler Name(params):` | macro | Generates typed async proc, return must be a `Response` |
| `middleware Name(ctx, next):` | macro | Generates typed async middleware proc |
| `newRoute(method, pattern, handler)` | macro | Creates a `RouteRef` entity with pattern baked into the type |
| `newRoute(method, pattern, handler, middleware)` | macro | Creates a `RouteRef` entity with middleware |
| `urlAs(pattern, ...)` | macro | Compile-time URL builder from a pattern string |
| `urlFor(route, ...)` | macro | Compile-time URL builder from a `RouteRef` entity |
| `RelRef` / `AbsRef` | enum | Relative (`"./..."`) or absolute (`"/..."`) URL mode |
| `withTimeout(ms)` | proc | Middleware: aborts handler after `ms` milliseconds (Http408) |
| `route Name:` | macro | Defines a route group |
| `newRouter()` | proc | Creates a new router |
| `router.addRoute(route)` | proc | Registers a `RouteRef` on the router |
| `router.mount(prefix, group)` | proc | Mounts a route group at prefix |
| `router.mount(prefix, group, middlewares)` | proc | Mounts a route group with group-level middleware |
| `router.use(middleware)` | proc | Adds global middleware |
| `router.onError(code, handler)` | proc | Registers a custom error handler for an HTTP status code |
| `router.addCDN(path)` | proc | Serves static files from a local directory |
| `router.addCDN(path, extensions, ignoreExtensions)` | proc | Serves static files with extension whitelist/blacklist |
| `router.addCDN(path, proxy)` | proc | Proxies requests to a remote CDN |
| `router.addCDN(path, proxy, extensions, ignoreExtensions)` | proc | Proxies requests with extension whitelist/blacklist |
| `router.serve(host, port)` | proc | Starts the HTTP server |
| `ctx.forward(method, path)` | proc | Internal dispatch through the router (supports relative paths) |
| `ctx.forward(method, path, query)` | proc | Internal dispatch with custom query parameters |
| `ctx.formData()` | proc | Parses request body as FormData (URL-encoded or multipart) |
| `form["key"]` | proc | Returns text field value (raises `KeyError` if missing) |
| `form.getField(key, default)` | proc | Returns text field value or default |
| `form.file(key)` | proc | Returns `UploadFile` (raises `KeyError` if missing) |
| `form.hasField(key)` | proc | Checks if text field exists |
| `form.hasFile(key)` | proc | Checks if uploaded file exists |
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
