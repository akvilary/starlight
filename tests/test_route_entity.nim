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

# --- Route entities ---

let userShow = newRoute(MethodGet, "/users/{name}", greetUser)
let postShow = newRoute(MethodGet, "/posts/{id:int}", getPost)
let protectedUser = newRoute(MethodGet, "/admin/{name}", greetUser, middleware = @[testMiddleware])

suite "newRoute + urlFor":
  test "urlFor with string param":
    check urlFor(userShow, name = "alice") == "/users/alice"

  test "urlFor with int param":
    check urlFor(postShow, id = 42) == "/posts/42"

  test "urlFor with variable":
    let name = "bob"
    check urlFor(userShow, name = name) == "/users/bob"

  test "urlFor with query params":
    check urlFor(userShow, name = "alice", tab = "posts") ==
      "/users/alice?tab=posts"

  test "urlFor with RelRef":
    check urlFor(userShow, RelRef, name = "alice") == "./users/alice"

  test "urlFor with AbsRef":
    check urlFor(userShow, AbsRef, name = "alice") == "/users/alice"

  test "urlFor RelRef with query params":
    check urlFor(postShow, RelRef, id = 42, sort = "date") ==
      "./posts/42?sort=date"

suite "add() in route groups":
  test "dispatch route added via add()":
    var router = newRouter()
    route Api:
      add(userShow)
    router.mount("/", Api)
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
    router.mount("/", Api)
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
    router.mount("/", Api)
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
      get("/health", healthCheck)
    router.mount("/", Api)

    let ctx1 = newContext()
    ctx1.path = "/users/bob"
    ctx1.httpMethod = MethodGet
    ctx1.router = router
    let res1 = waitFor router.dispatch(ctx1)
    check res1.body == "Hello, bob"

    let ctx2 = newContext()
    ctx2.path = "/health"
    ctx2.httpMethod = MethodGet
    ctx2.router = router
    let res2 = waitFor router.dispatch(ctx2)
    check res2.body == "OK"

suite "router.addRoute(route)":
  test "direct registration on router":
    var router = newRouter()
    router.addRoute(userShow)
    let ctx = newContext()
    ctx.path = "/users/charlie"
    ctx.httpMethod = MethodGet
    ctx.router = router
    let res = waitFor router.dispatch(ctx)
    check res.code == Http200
    check res.body == "Hello, charlie"

suite "mount with prefix":
  test "add() with mount prefix":
    var router = newRouter()
    route Api:
      add(userShow)
    router.mount("/api", Api)
    let ctx = newContext()
    ctx.path = "/api/users/alice"
    ctx.httpMethod = MethodGet
    ctx.router = router
    let res = waitFor router.dispatch(ctx)
    check res.code == Http200
    check res.body == "Hello, alice"
