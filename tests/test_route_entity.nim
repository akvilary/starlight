import std/unittest
import ../src/starlight

# --- Handlers ---

handler greetUser(ctx: Context, name: string) {.html.}:
  return "Hello, " & name

handler getPost(ctx: Context, id: int) {.html.}:
  return "Post #" & $id

handler healthCheck(ctx: Context) {.html.}:
  return "OK"

# --- Middleware ---

var middlewareCalled = false

proc testMiddleware(ctx: Context, next: HandlerProc): Future[Response] {.
    async: (raises: [CatchableError]).} =
  middlewareCalled = true
  return await next(ctx)

# --- Route entities (relative patterns for route groups) ---

let userShow = newRoute(MethodGet, "./{name}", greetUser)
let postShow = newRoute(MethodGet, "./{id:int}", getPost)
let protectedUser = newRoute(MethodGet, "./{name}", greetUser, middleware = @[testMiddleware])

suite "urlFor with relative patterns":
  test "relative by default when pattern starts with ./":
    check urlFor(userShow, name = "alice") == "./alice"

  test "int param":
    check urlFor(postShow, id = 42) == "./42"

  test "variable reference":
    let name = "bob"
    check urlFor(userShow, name = name) == "./bob"

  test "with query params":
    check urlFor(userShow, name = "alice", tab = "posts") ==
      "./alice?tab=posts"

  test "RelRef on relative pattern — no double ./":
    check urlFor(userShow, RelRef, name = "alice") == "./alice"

  test "RelRef on absolute pattern":
    let absRoute = newRoute(MethodGet, "/users/{name}", greetUser)
    check urlFor(absRoute, RelRef, name = "alice") == "./users/alice"

  test "absolute pattern stays absolute by default":
    let absRoute = newRoute(MethodGet, "/users/{name}", greetUser)
    check urlFor(absRoute, name = "alice") == "/users/alice"

suite "add() in route groups":
  test "dispatch relative route via add()":
    var router = newRouter()
    route Api:
      add(userShow)
    router.mount("/users", Api)
    let ctx = newContext()
    ctx.path = "/users/alice"
    ctx.httpMethod = MethodGet
    ctx.router = router
    let res = waitFor router.dispatch(ctx)
    check res.code == Http200
    check res.body == "Hello, alice"

  test "dispatch int param route via add()":
    var router = newRouter()
    route Api:
      add(postShow)
    router.mount("/posts", Api)
    let ctx = newContext()
    ctx.path = "/posts/42"
    ctx.httpMethod = MethodGet
    ctx.router = router
    let res = waitFor router.dispatch(ctx)
    check res.code == Http200
    check res.body == "Post #42"

  test "newRoute with middleware":
    middlewareCalled = false
    var router = newRouter()
    route Api:
      add(protectedUser)
    router.mount("/admin", Api)
    let ctx = newContext()
    ctx.path = "/admin/alice"
    ctx.httpMethod = MethodGet
    ctx.router = router
    let res = waitFor router.dispatch(ctx)
    check res.code == Http200
    check res.body == "Hello, alice"
    check middlewareCalled == true

  test "add() and get() coexist in same group":
    var router = newRouter()
    route Api:
      add(userShow)
      get("./health", healthCheck)
    router.mount("/users", Api)

    let ctx1 = newContext()
    ctx1.path = "/users/bob"
    ctx1.httpMethod = MethodGet
    ctx1.router = router
    let res1 = waitFor router.dispatch(ctx1)
    check res1.body == "Hello, bob"

    let ctx2 = newContext()
    ctx2.path = "/users/health"
    ctx2.httpMethod = MethodGet
    ctx2.router = router
    let res2 = waitFor router.dispatch(ctx2)
    check res2.body == "OK"

suite "router.addRoute(route)":
  test "direct registration with relative pattern":
    var router = newRouter()
    router.addRoute(userShow)
    let ctx = newContext()
    ctx.path = "/charlie"
    ctx.httpMethod = MethodGet
    ctx.router = router
    let res = waitFor router.dispatch(ctx)
    check res.code == Http200
    check res.body == "Hello, charlie"

  test "direct registration with absolute pattern":
    let absRoute = newRoute(MethodGet, "/users/{name}", greetUser)
    var router = newRouter()
    router.addRoute(absRoute)
    let ctx = newContext()
    ctx.path = "/users/charlie"
    ctx.httpMethod = MethodGet
    ctx.router = router
    let res = waitFor router.dispatch(ctx)
    check res.code == Http200
    check res.body == "Hello, charlie"

suite "mount with prefix":
  test "relative route + mount prefix":
    var router = newRouter()
    route Api:
      add(userShow)
    router.mount("/api/users", Api)
    let ctx = newContext()
    ctx.path = "/api/users/alice"
    ctx.httpMethod = MethodGet
    ctx.router = router
    let res = waitFor router.dispatch(ctx)
    check res.code == Http200
    check res.body == "Hello, alice"

  test "get() with relative pattern + mount":
    var router = newRouter()
    route Api:
      get("./{name}", greetUser)
    router.mount("/users", Api)
    let ctx = newContext()
    ctx.path = "/users/alice"
    ctx.httpMethod = MethodGet
    ctx.router = router
    let res = waitFor router.dispatch(ctx)
    check res.code == Http200
    check res.body == "Hello, alice"

  test "root pattern ./ + mount":
    var router = newRouter()
    route Api:
      get("./", healthCheck)
    router.mount("/health", Api)
    let ctx = newContext()
    ctx.path = "/health"
    ctx.httpMethod = MethodGet
    ctx.router = router
    let res = waitFor router.dispatch(ctx)
    check res.code == Http200
    check res.body == "OK"
