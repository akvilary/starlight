## Context helpers and response builders.

import std/[tables, json]
import chronos/apps/http/httpserver
import types

proc newContext*(): Context =
  Context(
    headers: HttpTable.init(),
    query: initTable[string, string](),
    pathParams: initTable[string, string](),
  )

proc getQuery*(ctx: Context, key: string, default: string = ""): string =
  ctx.query.getOrDefault(key, default)

proc jsonBody*[T](ctx: Context, t: typedesc[T]): T =
  let node = parseJson(ctx.body)
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

proc answer*(code: HttpCode): Response =
  Response(code: code, body: "",
           headers: HttpTable.init())

proc redirect*(url: string, code: HttpCode = Http302): Response =
  Response(code: code, body: "",
           headers: HttpTable.init([("Location", url)]))
