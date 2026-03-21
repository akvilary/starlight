import std/unittest
import ../src/starlight

# --- Handlers ---

handler setHandler(ctx: Context) {.html.}:
  ctx.session.set("name", "Alice")
  ctx.session.set("count", 42)
  ctx.session.set("score", 9.5)
  ctx.session.set("active", true)
  return "OK"

handler getHandler(ctx: Context) {.html.}:
  let name = ctx.session.get("name")
  let count = ctx.session.get("count", int)
  return name & ":" & $count

handler deleteHandler(ctx: Context) {.html.}:
  ctx.session.delete("name")
  return "deleted"

handler clearHandler(ctx: Context) {.html.}:
  ctx.session.clear()
  return "cleared"

handler readOnly(ctx: Context) {.html.}:
  return ctx.session.get("name", "guest")

# --- Setup ---

var store = newMemoryStore()
var router = newRouter()

route Api:
  get("./set", setHandler)
  get("./get", getHandler)
  get("./delete", deleteHandler)
  get("./clear", clearHandler)
  get("./read", readOnly)

router.mount("/", Api)
router.use(withSessions(store))

# --- Helper ---

proc dispatch(path: string, sessionCookie = ""): Response =
  let ctx = newContext()
  ctx.path = path
  ctx.httpMethod = MethodGet
  ctx.router = router
  if sessionCookie.len > 0:
    ctx.request.headers.add("cookie", "sid=" & sessionCookie)
  waitFor router.dispatch(ctx)

proc extractSid(res: Response): string =
  for cookie in res.headers.getList("set-cookie"):
    if cookie.startsWith("sid="):
      let eq = cookie.find('=')
      let semi = cookie.find(';')
      if semi > 0:
        return cookie[eq+1 ..< semi]
      return cookie[eq+1 .. ^1]
  return ""

# --- Tests ---

suite "Session object API":
  test "set and get string":
    let s = Session(id: "test")
    s.set("name", "Alice")
    check s.get("name") == "Alice"

  test "set and get int":
    let s = Session(id: "test")
    s.set("count", 42)
    check s.get("count", int) == 42

  test "set and get float":
    let s = Session(id: "test")
    s.set("score", 9.5)
    check s.get("score", float) == 9.5

  test "set and get bool":
    let s = Session(id: "test")
    s.set("active", true)
    check s.get("active", bool) == true

  test "get returns default when missing":
    let s = Session(id: "test")
    check s.get("missing") == ""
    check s.get("missing", "fallback") == "fallback"
    check s.get("missing", int) == 0
    check s.get("missing", int, 10) == 10
    check s.get("missing", float) == 0.0
    check s.get("missing", bool) == false

  test "get returns default on type mismatch":
    let s = Session(id: "test")
    s.set("name", "Alice")
    check s.get("name", int) == 0
    check s.get("name", int, 99) == 99

  test "delete removes key":
    let s = Session(id: "test")
    s.set("name", "Alice")
    s.delete("name")
    check s.get("name") == ""

  test "clear removes all":
    let s = Session(id: "test")
    s.set("a", "1")
    s.set("b", 2)
    s.clear()
    check s.get("a") == ""
    check s.get("b", int) == 0

  test "isModified flag":
    let s = Session(id: "test")
    check s.isModified == false
    s.set("key", "val")
    check s.isModified == true

  test "isModified on delete":
    let s = Session(id: "test")
    s.set("key", "val")
    s.isModified = false
    s.delete("key")
    check s.isModified == true

  test "isModified on clear":
    let s = Session(id: "test")
    s.set("key", "val")
    s.isModified = false
    s.clear()
    check s.isModified == true

suite "Session ID":
  test "generates 32-char hex":
    let id = generateSessionId()
    check id.len == 32
    for c in id:
      check c in {'0'..'9', 'a'..'f'}

  test "generates unique IDs":
    let a = generateSessionId()
    let b = generateSessionId()
    check a != b

suite "withSessions middleware":
  test "creates new session with Set-Cookie":
    let res = dispatch("/set")
    check res.code == Http200
    let sid = extractSid(res)
    check sid.len == 32

  test "loads existing session by cookie":
    let res1 = dispatch("/set")
    let sid = extractSid(res1)
    let res2 = dispatch("/get", sid)
    check res2.body == "Alice:42"

  test "session persists across requests":
    let res1 = dispatch("/set")
    let sid = extractSid(res1)
    let res2 = dispatch("/read", sid)
    check res2.body == "Alice"

  test "missing session creates new one":
    let res = dispatch("/read", "nonexistent")
    check res.body == "guest"
    let sid = extractSid(res)
    check sid.len == 32

  test "no cookie — new session":
    let res = dispatch("/read")
    check res.body == "guest"
    let sid = extractSid(res)
    check sid.len == 32

  test "delete key persists":
    let res1 = dispatch("/set")
    let sid = extractSid(res1)
    discard dispatch("/delete", sid)
    let res3 = dispatch("/read", sid)
    check res3.body == "guest"

  test "clear persists":
    let res1 = dispatch("/set")
    let sid = extractSid(res1)
    discard dispatch("/clear", sid)
    let res3 = dispatch("/get", sid)
    check res3.body == ":0"

  test "read-only request still creates session":
    let res = dispatch("/read")
    check res.body == "guest"
    # New session created — Set-Cookie header present
    check extractSid(res).len == 32
