import std/[unittest, options, strutils]
import ../src/starlight

# --- Handlers using ctx.cookies ---

handler loginHandler(ctx: Context) {.html.}:
  ctx.cookies.set("session", "abc123", httpOnly=true, secure=true, sameSite=Lax)
  return "Welcome"

handler multiCookieHandler(ctx: Context) {.html.}:
  ctx.cookies.set("session", "token", httpOnly=true)
  ctx.cookies.set("theme", "dark")
  return "OK"

handler deleteHandler(ctx: Context) {.html.}:
  ctx.cookies.delete("session", path="/")
  return "Bye"

handler readHandler(ctx: Context) {.html.}:
  return ctx.cookies.get("theme", "light")

# --- Router setup ---

var router = newRouter()

route Api:
  get("./login", loginHandler)
  get("./multi", multiCookieHandler)
  get("./logout", deleteHandler)
  get("./read", readHandler)

router.mount("/", Api)

# --- Helper ---

proc dispatch(path: string, cookieHeader = ""): Response =
  let ctx = newContext()
  ctx.path = path
  ctx.httpMethod = MethodGet
  ctx.router = router
  if cookieHeader.len > 0:
    ctx.request.headers.add("cookie", cookieHeader)
  waitFor router.dispatch(ctx)

# --- Tests ---

suite "cookies.get — reading":
  test "reads cookie from header":
    let ctx = newContext()
    ctx.request.headers.add("cookie", "theme=dark; lang=en")
    check ctx.cookies.get("theme") == "dark"
    check ctx.cookies.get("lang") == "en"

  test "returns default when missing":
    let ctx = newContext()
    check ctx.cookies.get("missing", "fallback") == "fallback"

  test "returns empty string when missing without default":
    let ctx = newContext()
    check ctx.cookies.get("missing") == ""

  test "multiple cookies in header":
    let ctx = newContext()
    ctx.request.headers.add("cookie", "a=1; b=2; c=3")
    check ctx.cookies.get("a") == "1"
    check ctx.cookies.get("b") == "2"
    check ctx.cookies.get("c") == "3"

  test "lazy parsing — not parsed until accessed":
    let ctx = newContext()
    ctx.request.headers.add("cookie", "x=y")
    check ctx.cookies.isParsed == false
    discard ctx.cookies.get("x")
    check ctx.cookies.isParsed == true

suite "cookies.set — handler pattern":
  test "set applies Set-Cookie to response via dispatch":
    let res = dispatch("/login")
    check res.code == Http200
    check res.body == "Welcome"
    let cookies = res.headers.getList("set-cookie")
    check cookies.len == 1
    check "session=abc123" in cookies[0]
    check "HttpOnly" in cookies[0]
    check "Secure" in cookies[0]
    check "SameSite=Lax" in cookies[0]

  test "multiple set calls":
    let res = dispatch("/multi")
    let cookies = res.headers.getList("set-cookie")
    check cookies.len == 2

  test "delete sets Max-Age=0":
    let res = dispatch("/logout")
    let cookies = res.headers.getList("set-cookie")
    check cookies.len == 1
    check "session=" in cookies[0]
    check "Max-Age=0" in cookies[0]
    check "Path=/" in cookies[0]

  test "get via dispatch":
    let res = dispatch("/read", "theme=dark")
    check res.body == "dark"

  test "get default via dispatch":
    let res = dispatch("/read")
    check res.body == "light"

suite "Response.withCookie — functional pattern":
  test "adds Set-Cookie header":
    let res = answer("OK").withCookie("token", "abc")
    let cookies = res.headers.getList("set-cookie")
    check cookies.len == 1
    check cookies[0] == "token=abc"

  test "withCookie with options":
    let res = answer("OK").withCookie("sid", "x",
      path="/", domain=".example.com",
      httpOnly=true, secure=true, sameSite=Strict)
    let cookie = res.headers.getList("set-cookie")[0]
    check "sid=x" in cookie
    check "Path=/" in cookie
    check "Domain=.example.com" in cookie
    check "HttpOnly" in cookie
    check "Secure" in cookie
    check "SameSite=Strict" in cookie

  test "withCookie with maxAge":
    let res = answer("OK").withCookie("k", "v", maxAge=some(3600))
    check "Max-Age=3600" in res.headers.getList("set-cookie")[0]

  test "chaining multiple withCookie":
    let res = answer("OK")
      .withCookie("a", "1")
      .withCookie("b", "2")
      .withCookie("c", "3")
    check res.headers.getList("set-cookie").len == 3

  test "generic value — int":
    let res = answer("OK").withCookie("count", 42)
    check "count=42" in res.headers.getList("set-cookie")[0]

  test "generic value — bool":
    let res = answer("OK").withCookie("active", true)
    check "active=true" in res.headers.getList("set-cookie")[0]

  test "deleteCookie on Response":
    let res = answer("OK").deleteCookie("session", path="/")
    let cookie = res.headers.getList("set-cookie")[0]
    check "session=" in cookie
    check "Max-Age=0" in cookie
    check "Path=/" in cookie
