import std/[unittest, options]
import ../src/starlight/[types, cdn, router, context]

# Fixtures live at tests/test_cdn/{public,assets}
# Tests run from the repo root via `nim c -r tests/test_cdn.nim`
const base = "tests/test_cdn"

suite "getMimeType":
  test "common types":
    check getMimeType("css") == "text/css"
    check getMimeType("js") == "application/javascript"
    check getMimeType("html") == "text/html"
    check getMimeType("json") == "application/json"
    check getMimeType("png") == "image/png"
    check getMimeType("jpg") == "image/jpeg"
    check getMimeType("svg") == "image/svg+xml"
    check getMimeType("woff2") == "font/woff2"

  test "unknown extension":
    check getMimeType("xyz") == "application/octet-stream"

suite "addCDN":
  test "local entry":
    let r = newRouter()
    r.addCDN("/public")
    check r.cdnDirs.len == 1
    check r.cdnDirs[0].path == "public"
    check r.cdnDirs[0].proxy == ""
    check r.cdnDirs[0].extensions.len == 0

  test "local entry with extensions":
    let r = newRouter()
    r.addCDN("/assets", extensions = ["css", "js"])
    check r.cdnDirs[0].extensions.len == 2
    check "css" in r.cdnDirs[0].extensions
    check "js" in r.cdnDirs[0].extensions

  test "proxy entry":
    let r = newRouter()
    r.addCDN("/libs", proxy = "https://cdn.example.com/npm")
    check r.cdnDirs[0].proxy == "https://cdn.example.com/npm"

  test "strips slashes from path":
    let r = newRouter()
    r.addCDN("/public/")
    check r.cdnDirs[0].path == "public"

suite "tryServeCDN — local files":
  setup:
    let r = newRouter()
    r.addCDN("/" & base & "/public")

  test "serves existing CSS file":
    let resp = waitFor r.tryServeCDN("/" & base & "/public/style.css")
    check resp.isSome
    let res = resp.get
    check res.code == Http200
    check "color: red" in res.body
    check res.headers.getString("content-type") == "text/css"

  test "serves existing JS file":
    let resp = waitFor r.tryServeCDN("/" & base & "/public/app.js")
    check resp.isSome
    check resp.get.headers.getString("content-type") == "application/javascript"

  test "returns none for non-existent file":
    let resp = waitFor r.tryServeCDN("/" & base & "/public/missing.css")
    check resp.isNone

  test "returns none for directory request":
    let resp = waitFor r.tryServeCDN("/" & base & "/public")
    check resp.isNone

  test "returns none for unmatched prefix":
    let resp = waitFor r.tryServeCDN("/other/style.css")
    check resp.isNone

suite "tryServeCDN — path traversal rejection":
  setup:
    let r = newRouter()
    r.addCDN("/" & base & "/public")

  test "rejects .. in path":
    let resp = waitFor r.tryServeCDN("/" & base & "/public/../assets/data.json")
    check resp.isNone

  test "rejects encoded ..":
    let resp = waitFor r.tryServeCDN("/" & base & "/public/..%2fassets/data.json")
    check resp.isNone

suite "tryServeCDN — extension filter":
  setup:
    let r = newRouter()
    r.addCDN("/" & base & "/assets", extensions = ["json"])

  test "serves allowed extension":
    let resp = waitFor r.tryServeCDN("/" & base & "/assets/data.json")
    check resp.isSome
    check resp.get.code == Http200

  test "rejects disallowed extension":
    let resp = waitFor r.tryServeCDN("/" & base & "/assets/blocked.txt")
    check resp.isNone

suite "dispatch integration — CDN fallback":
  setup:
    let r = newRouter()
    r.addCDN("/" & base & "/public")

  test "CDN serves file when no route matches":
    let ctx = newContext()
    ctx.path = "/" & base & "/public/style.css"
    ctx.httpMethod = MethodGet
    ctx.router = r
    let res = waitFor r.dispatch(ctx)
    check res.code == Http200
    check "color: red" in res.body

  test "CDN only on GET, POST returns 404":
    let ctx = newContext()
    ctx.path = "/" & base & "/public/style.css"
    ctx.httpMethod = MethodPost
    ctx.router = r
    let res = waitFor r.dispatch(ctx)
    check res.code == Http404
