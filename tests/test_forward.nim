import std/[unittest, json]
import ../src/starlight

handler greetUser(ctx: Context, name: string) {.html.}:
  return "Hello, " & name

handler fallback(ctx: Context) {.html.}:
  return await ctx.forward(MethodGet, "/users/default")

handler relative(ctx: Context) {.html.}:
  return await ctx.forward(MethodGet, "../bob")

handler searchHandler(ctx: Context) {.json.}:
  let q = ctx.getQuery("q")
  return %*{"query": q}

handler forwardWithQuery(ctx: Context) {.json.}:
  return await ctx.forward(MethodGet, "/api/search", {"q": "nim"}.toTable())

var router = newRouter()

route Users:
  get("./{name}", greetUser)

route Api:
  get("./search", searchHandler)
  get("./forward-search", forwardWithQuery)

route Main:
  get("./fallback", fallback)
  get("./users/alice", relative)

router.mount("/users", Users)
router.mount("/api", Api)
router.mount("/", Main)

suite "resolvePath":
  test "absolute path":
    check resolvePath("/users/alice", "/items/42") == "/items/42"

  test "relative ./":
    check resolvePath("/users/alice", "./profile") == "/users/alice/profile"

  test "relative ../":
    check resolvePath("/users/alice", "../bob") == "/users/bob"

  test "relative combined":
    check resolvePath("/users/alice", "../bob/profile") == "/users/bob/profile"

  test "relative from root":
    check resolvePath("/", "../anything") == "/anything"

  test "double ..":
    check resolvePath("/a/b/c", "../../x") == "/a/x"

suite "ctx.forward":
  test "forward with absolute path":
    let ctx = newContext()
    ctx.path = "/fallback"
    ctx.httpMethod = MethodGet
    ctx.router = router
    let res = waitFor router.dispatch(ctx)
    check res.code == Http200
    check res.body == "Hello, default"

  test "forward with relative path":
    let ctx = newContext()
    ctx.path = "/users/alice"
    ctx.httpMethod = MethodGet
    ctx.router = router
    let res = waitFor router.dispatch(ctx)
    check res.code == Http200
    check res.body == "Hello, bob"

  test "forward does not mutate original ctx":
    let ctx = newContext()
    ctx.path = "/original"
    ctx.httpMethod = MethodGet
    ctx.router = router
    let res = waitFor ctx.forward(MethodGet, "/users/charlie")
    check res.body == "Hello, charlie"
    check ctx.path == "/original"

  test "forward to non-existent route returns 404":
    let ctx = newContext()
    ctx.path = "/anything"
    ctx.httpMethod = MethodGet
    ctx.router = router
    let res = waitFor ctx.forward(MethodGet, "/nonexistent")
    check res.code == Http404

  test "forward with custom query parameters":
    let ctx = newContext()
    ctx.path = "/api/forward-search"
    ctx.httpMethod = MethodGet
    ctx.router = router
    let res = waitFor router.dispatch(ctx)
    check res.code == Http200
    check parseJson(res.body)["query"].getStr() == "nim"

  test "forward with query does not mutate original ctx":
    let ctx = newContext()
    ctx.path = "/anything"
    ctx.httpMethod = MethodGet
    ctx.router = router
    ctx.request.query["original"] = "yes"
    let res = waitFor ctx.forward(MethodGet, "/api/search", {"q": "test"}.toTable())
    check parseJson(res.body)["query"].getStr() == "test"
    check ctx.request.query["original"] == "yes"
    check "q" notin ctx.request.query
