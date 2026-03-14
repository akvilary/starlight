# Starlight

Super fast server-side rendering framework for Nim.

Starlight combines the stability of Prologue with the ergonomics of HappyX, while adding compile-time HTML optimization that makes it the fastest SSR framework in the Nim ecosystem.

## Features

- **Compile-time HTML optimization** — static parts of templates are pre-computed and baked into the binary. Only dynamic expressions are evaluated at runtime.
- **Native Nim syntax in HTML DSL** — no special syntax like `{var}` or `x->inc()`. Just write normal Nim code inside `layout` blocks.
- **PrefixTree router** — typed path parameters (`{id:int}`, `{slug}`, `{price:float}`) with compile-time validation.
- **Middleware chain** — explicit `next` callback pattern for predictable request processing.
- **Zero-overhead layouts** — `layout` generates inline procs with implicit context passing.
- **Single allocation rendering** — the HTML engine pre-calculates buffer size and builds the entire page in one string.

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

response home() -> htmlResponse:
  HomePage()

route Main:
  get "", home

var app = newApp()
app.mount("/", Main)
app.serve("127.0.0.1", 5000)
```

Run:

```
nim c -r main.nim
# Starlight listening on http://127.0.0.1:5000
```

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
response home() -> htmlResponse:
  Page(pageTitle="Home", content=Card(title="Welcome", body="Hello!"))
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

The `response` macro generates async handler procs. Use `-> htmlResponse` for HTML or `-> jsonResponse` for JSON:

### HTML Handler

```nim
response home() -> htmlResponse:
  Page(pageTitle="Home", content=HomePage())
```

### JSON Handler

```nim
response getStatus() -> jsonResponse:
  %*{"status": "ok", "version": "0.1.0"}
```

### Path Parameters

Path parameters are declared in the handler signature with their types. They are automatically extracted from `ctx.pathParams` and converted to the specified type:

```nim
# Route: get "/{name}", getUser
response getUser(name: string) -> htmlResponse:
  # name is automatically bound from ctx.pathParams["name"]
  Page(pageTitle=name, content=UserProfile(name=name))

# Route: get "/{id:int}", getItem
response getItem(id: int) -> jsonResponse:
  # id is automatically parsed as int from ctx.pathParams["id"]
  let item = fetchItem(id)
  %*{"id": id, "name": item.name}
```

### Accessing Request Context

The `ctx` object is available in every handler:

```nim
response search() -> jsonResponse:
  let query = ctx.getQuery("q")
  let token = ctx.headers["Authorization"]
  let data = parseJson(ctx.body)
  %*{"query": query, "ip": ctx.ip}
```

## Routing

### Route Groups

Define route groups with the `route` macro. Register handlers by HTTP method:

```nim
route UsersApi:
  get "", listUsers
  get "/{name}", getUser
  post "", createUser

route ApiRoutes:
  get "/status", getStatus
  post "/echo", echoBody
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
    result = answer(%*{"error": "Unauthorized"}, Http401)
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

response listUsers() -> htmlResponse:
  let users = @["Alice", "Bob", "Charlie"]
  Page(pageTitle="Users", content=UserList(users=users))

response getUser(name: string) -> htmlResponse:
  Page(pageTitle=name, content=UserProfile(name=name))

response getStatus() -> jsonResponse:
  %*{"status": "ok"}

response home() -> htmlResponse:
  Page(pageTitle="Home", content=HomePage())

# --- Routes ---

route UsersApi:
  get "", listUsers
  get "/{name}", getUser

route ApiRoutes:
  get "/status", getStatus

route Main:
  get "", home

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
| `response Name(params) -> type:` | macro | Defines an async handler proc |
| `route Name:` | macro | Defines a route group |
| `newApp()` | proc | Creates a new application |
| `app.mount(prefix, group)` | proc | Mounts a route group at prefix |
| `app.use(middleware)` | proc | Adds global middleware |
| `app.serve(host, port)` | proc | Starts the HTTP server |
| `answer(body, code)` | proc | Builds a Response object |
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

## License

MIT
