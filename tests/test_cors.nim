import std/unittest
import ../src/starlight

handler echoHandler(ctx: Context) {.html.}:
  return "Hello"

proc corsRequest(
  mw: MiddlewareProc,
  origin: string,
  httpMethod = MethodGet,
): Response =
  let ctx = newContext()
  ctx.httpMethod = httpMethod
  if origin.len > 0:
    ctx.request.headers.add("origin", origin)
  let chain = buildChain(echoHandler, @[mw])
  waitFor chain(ctx)

suite "withCors preflight":
  test "OPTIONS returns 204 with CORS headers":
    let mw = withCors()
    let res = corsRequest(mw, "https://example.com", MethodOptions)
    check res.code == Http204
    check res.body == ""
    check res.headers.getString("access-control-allow-origin") == "*"
    check res.headers.getString("access-control-allow-methods").len > 0

  test "OPTIONS with specific origins echoes request origin":
    let mw = withCors(origins = @["https://app.com"])
    let res = corsRequest(mw, "https://app.com", MethodOptions)
    check res.code == Http204
    check res.headers.getString("access-control-allow-origin") == "https://app.com"
    check res.headers.getString("vary") == "Origin"

  test "OPTIONS does not call handler":
    let mw = withCors()
    let res = corsRequest(mw, "https://example.com", MethodOptions)
    check res.code == Http204
    check res.body == ""

  test "OPTIONS with credentials echoes origin, not wildcard":
    let mw = withCors(credentials = true)
    let res = corsRequest(mw, "https://app.com", MethodOptions)
    check res.headers.getString("access-control-allow-origin") == "https://app.com"
    check res.headers.getString("access-control-allow-credentials") == "true"
    check res.headers.getString("vary") == "Origin"

  test "OPTIONS with maxAge includes Max-Age header":
    let mw = withCors(maxAge = 86400)
    let res = corsRequest(mw, "https://example.com", MethodOptions)
    check res.headers.getString("access-control-max-age") == "86400"

  test "OPTIONS without maxAge omits Max-Age header":
    let mw = withCors()
    let res = corsRequest(mw, "https://example.com", MethodOptions)
    check res.headers.getString("access-control-max-age") == ""

  test "OPTIONS with custom methods":
    let mw = withCors(methods = @[MethodGet, MethodPost])
    let res = corsRequest(mw, "https://example.com", MethodOptions)
    check res.headers.getString("access-control-allow-methods") == "GET, POST"

  test "OPTIONS with custom headers":
    let mw = withCors(headers = @["Content-Type", "Authorization"])
    let res = corsRequest(mw, "https://example.com", MethodOptions)
    check res.headers.getString("access-control-allow-headers") == "Content-Type, Authorization"

  test "OPTIONS with default headers returns wildcard":
    let mw = withCors()
    let res = corsRequest(mw, "https://example.com", MethodOptions)
    check res.headers.getString("access-control-allow-headers") == "*"

suite "withCors normal requests":
  test "GET with valid origin adds CORS headers":
    let mw = withCors()
    let res = corsRequest(mw, "https://example.com")
    check res.code == Http200
    check res.body == "Hello"
    check res.headers.getString("access-control-allow-origin") == "*"

  test "GET with specific origin echoes origin":
    let mw = withCors(origins = @["https://app.com"])
    let res = corsRequest(mw, "https://app.com")
    check res.headers.getString("access-control-allow-origin") == "https://app.com"
    check res.headers.getString("vary") == "Origin"

  test "GET with credentials adds credential header":
    let mw = withCors(credentials = true)
    let res = corsRequest(mw, "https://app.com")
    check res.headers.getString("access-control-allow-credentials") == "true"

  test "GET with exposeHeaders adds expose header":
    let mw = withCors(exposeHeaders = @["X-Request-Id", "X-Total-Count"])
    let res = corsRequest(mw, "https://example.com")
    check res.headers.getString("access-control-expose-headers") == "X-Request-Id, X-Total-Count"

  test "response body and code preserved":
    let mw = withCors()
    let res = corsRequest(mw, "https://example.com")
    check res.code == Http200
    check res.body == "Hello"

suite "withCors origin validation":
  test "unlisted origin gets no CORS headers":
    let mw = withCors(origins = @["https://allowed.com"])
    let res = corsRequest(mw, "https://blocked.com")
    check res.code == Http200
    check res.body == "Hello"
    check res.headers.getString("access-control-allow-origin") == ""

  test "listed origin gets CORS headers":
    let mw = withCors(origins = @["https://allowed.com"])
    let res = corsRequest(mw, "https://allowed.com")
    check res.headers.getString("access-control-allow-origin") == "https://allowed.com"

  test "multiple allowed origins":
    let mw = withCors(origins = @["https://a.com", "https://b.com"])
    let resA = corsRequest(mw, "https://a.com")
    let resB = corsRequest(mw, "https://b.com")
    check resA.headers.getString("access-control-allow-origin") == "https://a.com"
    check resB.headers.getString("access-control-allow-origin") == "https://b.com"

  test "wildcard origin allows any":
    let mw = withCors(origins = @["*"])
    let res = corsRequest(mw, "https://anything.com")
    check res.headers.getString("access-control-allow-origin") == "*"

  test "empty origins (default) allows any":
    let mw = withCors()
    let res = corsRequest(mw, "https://anything.com")
    check res.headers.getString("access-control-allow-origin") == "*"

suite "withCors edge cases":
  test "missing Origin header — no CORS headers":
    let mw = withCors()
    let res = corsRequest(mw, "")
    check res.code == Http200
    check res.body == "Hello"
    check res.headers.getString("access-control-allow-origin") == ""

  test "credentials with wildcard origins echoes origin":
    let mw = withCors(credentials = true)
    let res = corsRequest(mw, "https://app.com")
    check res.headers.getString("access-control-allow-origin") == "https://app.com"
    check res.headers.getString("vary") == "Origin"

  test "wildcard without credentials uses * (no Vary)":
    let mw = withCors()
    let res = corsRequest(mw, "https://app.com")
    check res.headers.getString("access-control-allow-origin") == "*"
    check res.headers.getString("vary") == ""

suite "OPTIONS fallback in router":
  test "OPTIONS preflight works for path with GET handler":
    var router = newRouter()
    router.use(withCors(origins = @["https://app.com"]))

    route Api:
      get("./data", echoHandler)

    router.mount("/api", Api)

    let ctx = newContext()
    ctx.path = "/api/data"
    ctx.httpMethod = MethodOptions
    ctx.request.headers.add("origin", "https://app.com")
    ctx.router = router

    let res = waitFor router.dispatch(ctx)
    check res.code == Http204
    check res.headers.getString("access-control-allow-origin") == "https://app.com"

  test "OPTIONS for non-existent path returns 404":
    var router = newRouter()
    router.use(withCors())

    let ctx = newContext()
    ctx.path = "/does-not-exist"
    ctx.httpMethod = MethodOptions
    ctx.router = router

    let res = waitFor router.dispatch(ctx)
    check res.code == Http404
