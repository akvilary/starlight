import std/json
import ../src/starlight

# --- Layouts ---

layout Page(title: string, content: string):
  Html:
    Head:
      Meta(charset="utf-8")
      Title: title
      Style: "body { font-family: sans-serif; max-width: 800px; margin: 0 auto; padding: 20px; }"
    Body:
      Nav:
        A(href="/"): "Home"
        raw " | "
        A(href="/users"): "Users"
        raw " | "
        A(href="/about"): "About"
      Hr
      raw content

layout UserList(users: seq[string]):
  H1: "Users"
  Ul:
    for user in users:
      Li:
        A(href="/users/" & user): user

layout UserProfile(name: string):
  H1: "User: " & name
  P: "Profile page for " & name
  A(href="/users"): "Back to users"

layout HomePage():
  H1: "Welcome to Starlight"
  P: "A super fast server-side rendering framework for Nim."
  Div(class="features"):
    H2: "Features"
    Ul:
      Li: "Compile-time HTML optimization"
      Li: "PrefixTree router with typed parameters"
      Li: "Middleware chain"
      Li: "Zero-overhead layouts"

layout AboutPage():
  H1: "About"
  P: "Built with Nim and Chronos."

layout NotFoundPage():
  H1: "404 — Not Found"
  P: "The page you are looking for does not exist."

# --- Handlers ---
# Each handler is a typed proc. Direct call: await getUser(ctx, "Alice")

handler listUsers(ctx: Context) {.html.}:
  let users = @["Alice", "Bob", "Charlie"]
  return Page(title="Users", content=UserList(users=users))

handler getUser(ctx: Context, name: string) {.html.}:
  return Page(title=name, content=UserProfile(name=name))

handler getStatus(ctx: Context) {.json.}:
  return %*{"status": "ok", "version": "0.1.0"}

handler echoBody(ctx: Context) {.json.}:
  return parseJson(ctx.request.body)

handler unauthorized(ctx: Context) {.json.}:
  return (%*{"error": "not authorized"}, Http401)

handler homePage(ctx: Context) {.html.}:
  return Page(title="Starlight", content=HomePage())

handler aboutPage(ctx: Context) {.html.}:
  return Page(title="About", content=AboutPage())

handler notFoundPage(ctx: Context) {.html.}:
  return (Page(title="404", content=NotFoundPage()), Http404)

# --- Route groups ---

route UsersApi:
  get("", listUsers)
  get("/{name}", getUser)

route ApiRoutes:
  get("/status", getStatus)
  post("/echo", echoBody)
  get("/unauthorized", unauthorized)

route MainPage:
  get("", homePage)
  get("/about", aboutPage)
  get("/not-found", notFoundPage)

# --- Middleware ---

proc loggingMiddleware(
  ctx: Context,
  next: HandlerProc,
): Future[Response] {.async: (raises: [CatchableError]).} =
  echo ctx.httpMethod, " ", ctx.path
  result = await next(ctx)

# --- Router ---

var router = newRouter()
router.use(loggingMiddleware)
router.mount("/users", UsersApi)
router.mount("/api", ApiRoutes)
router.mount("/", MainPage)

router.serve("127.0.0.1", 5000)
