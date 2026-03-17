import std/unittest
import ../src/starlight

handler greetUser(name: string) {.html.}:
  return "Hello, " & name

handler fallback() {.html.}:
  return await ctx.forward(MethodGet, "/users/default")

handler relative() {.html.}:
  return await ctx.forward(MethodGet, "../bob")

var router = newRouter()

route Users:
  get("/{name}", greetUser)

route Main:
  get("/fallback", fallback)
  get("/users/alice", relative)

router.mount("/users", Users)
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
