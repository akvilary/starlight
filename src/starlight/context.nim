## Context helpers and response builders.

import std/[tables, json]
import chronos/apps/http/httpserver
import types

proc newRequestData*(): RequestData =
  RequestData(
    headers: HttpTable.init(),
    query: initTable[string, string](),
  )

proc newContext*(): Context =
  Context(
    pathParams: initTable[string, string](),
    request: newRequestData(),
  )

proc clone*(ctx: Context): Context =
  ## Creates a lightweight copy for internal dispatch.
  ## RequestData is shared (not copied) — headers, body, query, ip
  ## are the same ref. Only path, method and pathParams are new.
  Context(
    path: ctx.path,
    httpMethod: ctx.httpMethod,
    pathParams: initTable[string, string](),
    request: ctx.request,
    router: ctx.router,
  )

# --- RequestData accessors on Context ---

proc headers*(ctx: Context): HttpTable {.inline.} = ctx.request.headers
proc body*(ctx: Context): string {.inline.} = ctx.request.body
proc query*(ctx: Context): Table[string, string] {.inline.} = ctx.request.query
proc ip*(ctx: Context): string {.inline.} = ctx.request.ip

proc `body=`*(ctx: Context, value: string) {.inline.} =
  ctx.request.body = value

proc `ip=`*(ctx: Context, value: string) {.inline.} =
  ctx.request.ip = value

proc `headers=`*(ctx: Context, value: HttpTable) {.inline.} =
  ctx.request.headers = value

proc `query=`*(ctx: Context, value: Table[string, string]) {.inline.} =
  ctx.request.query = value

proc getQuery*(ctx: Context, key: string, default: string = ""): string =
  ctx.request.query.getOrDefault(key, default)

proc jsonBody*[T](ctx: Context, t: typedesc[T]): T =
  let node = parseJson(ctx.request.body)
  result = to(node, T)

# --- Response builders ---

proc answer*(body: string, code: HttpCode = Http200): Response =
  Response(code: code, body: body,
           headers: HttpTable.init([("Content-Type", "text/html; charset=utf-8")]))

proc answerJson*(body: string, code: HttpCode = Http200): Response =
  Response(code: code, body: body,
           headers: HttpTable.init([("Content-Type", "application/json; charset=utf-8")]))

proc answerJson*(body: JsonNode, code: HttpCode = Http200): Response =
  Response(code: code, body: $body,
           headers: HttpTable.init([("Content-Type", "application/json; charset=utf-8")]))

proc answer*(res: Response): Response = res

proc answerJson*(res: Response): Response = res

proc answer*(code: HttpCode): Response =
  Response(code: code, body: "",
           headers: HttpTable.init())

proc redirect*(url: string, code: HttpCode = Http302): Response =
  Response(code: code, body: "",
           headers: HttpTable.init([("Location", url)]))
