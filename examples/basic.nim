import std/json
import ../src/starlight

# --- Layouts ---

layout Page(title: string, content: string):
  html:
    head:
      meta(charset="utf-8")
      title: title
      style: "body { font-family: sans-serif; max-width: 800px; margin: 0 auto; padding: 20px; }"
    body:
      nav:
        a(href="/"): "Home"
        text " | "
        a(href="/users"): "Users"
        text " | "
        a(href="/about"): "About"
      hr
      raw content

layout UserList(users: seq[string]):
  h1: "Users"
  ul:
    for user in users:
      li:
        a(href="/users/" & user): user

layout UserProfile(name: string):
  h1: "User: " & name
  p: "Profile page for " & name
  a(href="/users"): "Back to users"

layout HomePage():
  h1: "Welcome to Starlight"
  p: "A super fast server-side rendering framework for Nim."
  tdiv(class="features"):
    h2: "Features"
    ul:
      li: "Compile-time HTML optimization"
      li: "PrefixTree router with typed parameters"
      li: "Middleware chain"
      li: "Zero-overhead layouts"

layout AboutPage():
  h1: "About"
  p: "Built with Nim and httpx."

# --- Handlers ---

responseHtml listUsers():
  let users = @["Alice", "Bob", "Charlie"]
  return Page(title="Users", content=UserList(users=users))

responseHtml getUser(name: string):
  return Page(title=name, content=UserProfile(name=name))

responseJson getStatus():
  return %*{"status": "ok", "version": "0.1.0"}

responseJson echoBody():
  return parseJson(ctx.body)

responseHtml homePage():
  return Page(title="Starlight", content=HomePage())

responseHtml aboutPage():
  return Page(title="About", content=AboutPage())

# --- Route groups ---

route UsersApi:
  get "", listUsers
  get "/{name}", getUser

route ApiRoutes:
  get "/status", getStatus
  post "/echo", echoBody

route MainPage:
  get "", homePage
  get "/about", aboutPage

# --- Middleware ---

proc loggingMiddleware(ctx: Context, next: HandlerProc): Future[Response] {.
    async: (raises: [CatchableError]), gcsafe.} =
  echo ctx.httpMethod, " ", ctx.path
  result = await next(ctx)

# --- App ---

var app = newApp()
app.use(loggingMiddleware)
app.mount("/users", UsersApi)
app.mount("/api", ApiRoutes)
app.mount("/", MainPage)

app.serve("127.0.0.1", 5000)
