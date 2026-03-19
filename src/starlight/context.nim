## Context helpers and response builders.

import std/[tables, json]
import chronos/apps/http/httpserver
import types, form

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

proc getQuery*(ctx: Context, key: string, default: string = ""): string =
  ctx.request.query.getOrDefault(key, default)

proc jsonBody*[T](ctx: Context, t: typedesc[T]): T =
  let node = parseJson(ctx.request.body)
  result = to(node, T)

proc formData*(ctx: Context): FormData =
  ## Parses the request body as form data (URL-encoded or multipart).
  parseFormData(ctx.request.body, ctx.request.headers)

# --- Response builders ---

proc buildResponse(
  body: string,
  contentType: string,
  code: HttpCode = Http200,
): Response =
  Response(code: code, body: body,
           headers: HttpTable.init([("Content-Type", contentType)]))

proc errorResponse*(code: HttpCode, message: string): Response =
  buildResponse(message, "text/plain", code)

proc answer*(body: string, code: HttpCode = Http200): Response =
  buildResponse(body, "text/html; charset=utf-8", code)

proc answerJson*(body: string, code: HttpCode = Http200): Response =
  buildResponse(body, "application/json; charset=utf-8", code)

proc answerJson*(body: JsonNode, code: HttpCode = Http200): Response =
  buildResponse($body, "application/json; charset=utf-8", code)

proc answer*(res: Response): Response = res

proc answerJson*(res: Response): Response = res

proc answer*(code: HttpCode): Response =
  Response(code: code, body: "",
           headers: HttpTable.init())

proc redirect*(url: string, code: HttpCode = Http302): Response =
  Response(code: code, body: "",
           headers: HttpTable.init([("Location", url)]))
