import std/unittest
import ../src/starlight

handler normalRoute(ctx: Context) {.html.}:
  return "OK"

handler custom404(ctx: Context) {.html.}:
  return ("Custom 404: " & ctx.path, Http404)

handler custom500(ctx: Context) {.html.}:
  return ("Custom 500", Http500)

handler throwing500(ctx: Context):
  raise newException(CatchableError, "handler crashed")

suite "custom error pages":
  test "default 404 when no custom handler":
    let r = newRouter()
    r.addRoute(MethodGet, "/", normalRoute)
    let ctx = newContext()
    ctx.path = "/nonexistent"
    ctx.httpMethod = MethodGet
    ctx.router = r
    let res = waitFor r.dispatch(ctx)
    check res.code == Http404
    check res.body == "Not Found"

  test "custom 404 handler":
    let r = newRouter()
    r.addRoute(MethodGet, "/", normalRoute)
    r.onError(Http404, custom404)
    let ctx = newContext()
    ctx.path = "/nonexistent"
    ctx.httpMethod = MethodGet
    ctx.router = r
    let res = waitFor r.dispatch(ctx)
    check res.code == Http404
    check "Custom 404" in res.body

  test "custom 404 receives request path":
    let r = newRouter()
    r.onError(Http404, custom404)
    let ctx = newContext()
    ctx.path = "/missing/page"
    ctx.httpMethod = MethodGet
    ctx.router = r
    let res = waitFor r.dispatch(ctx)
    check res.body == "Custom 404: /missing/page"

  test "custom 500 via resolveError":
    let r = newRouter()
    r.onError(Http500, custom500)
    let ctx = newContext()
    ctx.path = "/"
    ctx.httpMethod = MethodGet
    ctx.router = r
    let res = waitFor r.resolveError(ctx, Http500, "Internal Server Error")
    check res.code == Http500
    check res.body == "Custom 500"

  test "throwing custom handler falls back to plain text":
    let r = newRouter()
    r.onError(Http500, throwing500)
    let ctx = newContext()
    ctx.path = "/"
    ctx.httpMethod = MethodGet
    ctx.router = r
    let res = waitFor r.resolveError(ctx, Http500, "Internal Server Error")
    check res.code == Http500
    check res.body == "Internal Server Error"

  test "resolveError without custom handler returns plain text":
    let r = newRouter()
    let ctx = newContext()
    ctx.path = "/"
    ctx.httpMethod = MethodGet
    ctx.router = r
    let res = waitFor r.resolveError(ctx, Http500, "Internal Server Error")
    check res.code == Http500
    check res.body == "Internal Server Error"

  test "multiple error codes registered":
    let r = newRouter()
    r.onError(Http404, custom404)
    r.onError(Http500, custom500)
    let ctx = newContext()
    ctx.path = "/test"
    ctx.httpMethod = MethodGet
    ctx.router = r
    let res404 = waitFor r.resolveError(ctx, Http404, "Not Found")
    let res500 = waitFor r.resolveError(ctx, Http500, "Internal Server Error")
    check res404.code == Http404
    check "Custom 404" in res404.body
    check res500.code == Http500
    check res500.body == "Custom 500"
