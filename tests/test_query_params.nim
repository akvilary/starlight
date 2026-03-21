import std/[unittest, json, tables]
import ../src/starlight

# --- Handlers with query params ---

handler searchRequired(ctx: Context, q: string) {.html.}:
  return q

handler searchOptional(ctx: Context, q = "default") {.html.}:
  return q

handler listWithPage(ctx: Context, page = 1) {.html.}:
  return "page:" & $page

handler requiredInt(ctx: Context, id: int) {.html.}:
  return "id:" & $id

handler multiQuery(ctx: Context, q: string, page = 1, sort = "date") {.json.}:
  return %*{"q": q, "page": page, "sort": sort}

handler mixedParams(ctx: Context, name: string, tab = "info") {.html.}:
  return name & ":" & tab

handler boolQuery(ctx: Context, active = false) {.html.}:
  return $active

handler floatQuery(ctx: Context, amount: float) {.html.}:
  return $amount

# --- Router setup ---

var router = newRouter()

route Api:
  get("./search", searchRequired)
  get("./search-opt", searchOptional)
  get("./list", listWithPage)
  get("./item", requiredInt)
  get("./multi", multiQuery)
  get("./{name}", mixedParams)
  get("./toggle", boolQuery)
  get("./price", floatQuery)

router.mount("/api", Api)

# --- newRoute with query params ---

let searchRoute = newRoute(MethodGet, "./find", searchRequired)
route NewRouteApi:
  add(searchRoute)
router.mount("/v2", NewRouteApi)

# --- Helper ---

proc dispatch(
  path: string,
  query: Table[string, string] = default(Table[string, string]),
): Response =
  let ctx = newContext()
  ctx.path = path
  ctx.httpMethod = MethodGet
  ctx.router = router
  ctx.request.query = query
  waitFor router.dispatch(ctx)

# --- Tests ---

suite "typed query parameters":
  test "required string query param":
    let res = dispatch("/api/search", {"q": "nim"}.toTable())
    check res.code == Http200
    check res.body == "nim"

  test "missing required string query param returns 400":
    let res = dispatch("/api/search")
    check res.code == Http400

  test "optional string query param with value":
    let res = dispatch("/api/search-opt", {"q": "custom"}.toTable())
    check res.code == Http200
    check res.body == "custom"

  test "optional string query param uses default":
    let res = dispatch("/api/search-opt")
    check res.code == Http200
    check res.body == "default"

  test "optional int query param uses default":
    let res = dispatch("/api/list")
    check res.code == Http200
    check res.body == "page:1"

  test "optional int query param with value":
    let res = dispatch("/api/list", {"page": "3"}.toTable())
    check res.code == Http200
    check res.body == "page:3"

  test "required int query param":
    let res = dispatch("/api/item", {"id": "42"}.toTable())
    check res.code == Http200
    check res.body == "id:42"

  test "missing required int query param returns 400":
    let res = dispatch("/api/item")
    check res.code == Http400

  test "invalid int value returns 400":
    let res = dispatch("/api/list", {"page": "abc"}.toTable())
    check res.code == Http400

  test "multiple query params":
    let res = dispatch("/api/multi",
      {"q": "nim", "page": "2", "sort": "name"}.toTable())
    check res.code == Http200
    let body = parseJson(res.body)
    check body["q"].getStr() == "nim"
    check body["page"].getInt() == 2
    check body["sort"].getStr() == "name"

  test "multiple query params with defaults":
    let res = dispatch("/api/multi", {"q": "nim"}.toTable())
    check res.code == Http200
    let body = parseJson(res.body)
    check body["q"].getStr() == "nim"
    check body["page"].getInt() == 1
    check body["sort"].getStr() == "date"

  test "mix of path and query params":
    let res = dispatch("/api/alice", {"tab": "posts"}.toTable())
    check res.code == Http200
    check res.body == "alice:posts"

  test "mix of path and query params with default":
    let res = dispatch("/api/bob")
    check res.code == Http200
    check res.body == "bob:info"

  test "bool query param":
    let res = dispatch("/api/toggle", {"active": "true"}.toTable())
    check res.code == Http200
    check res.body == "true"

  test "bool query param uses default":
    let res = dispatch("/api/toggle")
    check res.code == Http200
    check res.body == "false"

  test "float query param":
    let res = dispatch("/api/price", {"amount": "9.99"}.toTable())
    check res.code == Http200
    check res.body == "9.99"

  test "missing required float returns 400":
    let res = dispatch("/api/price")
    check res.code == Http400

  test "invalid float value returns 400":
    let res = dispatch("/api/price", {"amount": "not-a-number"}.toTable())
    check res.code == Http400

  test "newRoute with query params":
    let res = dispatch("/v2/find", {"q": "test"}.toTable())
    check res.code == Http200
    check res.body == "test"
