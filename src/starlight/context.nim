## Context helpers and response builders.

import std/[tables, json, strutils, options]
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

# --- Cookies ---

proc parseCookieHeader(header: string): Table[string, string] =
  result = initTable[string, string]()
  if header.len == 0: return
  for pair in header.split("; "):
    let eq = pair.find('=')
    if eq > 0:
      result[pair[0..<eq]] = pair[eq+1..^1]

proc getCookie*(ctx: Context, name: string, default: string = ""): string =
  ## Reads a cookie value from the request Cookie header.
  ## Lazy: parses on first access, then O(1) table lookups.
  if not ctx.request.cookiesParsed:
    ctx.request.cookies = parseCookieHeader(
      ctx.request.headers.getString("cookie"))
    ctx.request.cookiesParsed = true
  ctx.request.cookies.getOrDefault(name, default)

proc formatCookie*[T](
  key: string,
  value: T,
  domain = "",
  path = "",
  expires = "",
  maxAge = none(int),
  secure = false,
  httpOnly = false,
  sameSite = SameSite.Default,
): string =
  ## Formats a Set-Cookie header value.
  result = key & "=" & $value
  if domain.len > 0: result &= "; Domain=" & domain
  if path.len > 0: result &= "; Path=" & path
  if expires.len > 0: result &= "; Expires=" & expires
  if maxAge.isSome: result &= "; Max-Age=" & $maxAge.get
  if httpOnly: result &= "; HttpOnly"
  if secure: result &= "; Secure"
  case sameSite
  of Lax: result &= "; SameSite=Lax"
  of Strict: result &= "; SameSite=Strict"
  of None: result &= "; SameSite=None"
  of Default: discard

proc withCookie*[T](
  res: Response,
  key: string,
  value: T,
  domain = "",
  path = "",
  expires = "",
  maxAge = none(int),
  secure = false,
  httpOnly = false,
  sameSite = SameSite.Default,
): Response =
  ## Returns a new Response with a Set-Cookie header added.
  result = res
  result.headers.add("Set-Cookie",
    formatCookie(key, value, domain, path, expires,
      maxAge, secure, httpOnly, sameSite))

proc deleteCookie*(
  res: Response,
  key: string,
  domain = "",
  path = "",
): Response =
  ## Returns a new Response with a cookie deletion header (Max-Age=0).
  res.withCookie(key, "", domain=domain, path=path, maxAge=some(0))

proc setCookie*[T](
  ctx: Context,
  key: string,
  value: T,
  domain = "",
  path = "",
  expires = "",
  maxAge = none(int),
  secure = false,
  httpOnly = false,
  sameSite = SameSite.Default,
) =
  ## Queues a Set-Cookie header to be sent with the response.
  ## Cookies are applied to the response by the router dispatch.
  ctx.outCookies.add(formatCookie(key, value, domain, path, expires,
    maxAge, secure, httpOnly, sameSite))

proc deleteCookie*(ctx: Context, key: string, domain = "", path = "") =
  ## Queues a cookie deletion header (Max-Age=0).
  ctx.setCookie(key, "", domain=domain, path=path, maxAge=some(0))
