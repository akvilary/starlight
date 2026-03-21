## CORS middleware for cross-origin resource sharing.

import std/[sets, strutils]
import types

const defaultMethods = @[
  MethodGet, MethodHead, MethodPost, MethodOptions,
  MethodPut, MethodPatch, MethodDelete,
]

proc withCors*(
  origins: seq[string] = default(seq[string]),
  methods: seq[HttpMethod] = default(seq[HttpMethod]),
  headers: seq[string] = default(seq[string]),
  exposeHeaders: seq[string] = default(seq[string]),
  credentials: bool = false,
  maxAge: int = 0,
): MiddlewareProc =
  ## Returns a middleware that adds CORS headers to responses.
  ##
  ##   router.use(withCors())                                  # allow all
  ##   router.use(withCors(origins = @["https://example.com"]))
  ##   router.use(withCors(credentials = true, maxAge = 86400))
  let allowAll = origins.len == 0 or "*" in origins
  let allowedOrigins = origins.toHashSet()

  let activeMethods = if methods.len == 0: defaultMethods else: methods
  var methodParts: seq[string]
  for m in activeMethods:
    methodParts.add($m)
  let methodsHeader = methodParts.join(", ")

  let headersHeader = if headers.len == 0: "*" else: headers.join(", ")
  let exposeHeader = exposeHeaders.join(", ")

  return proc(
    ctx: Context,
    next: HandlerProc,
  ): Future[Response] {.async: (raises: [CatchableError]), gcsafe.} =
    let origin = ctx.request.headers.getString("origin")

    # No Origin header — not a CORS request
    if origin.len == 0:
      return await next(ctx)

    # Origin not allowed — pass through without CORS headers
    if not allowAll and origin notin allowedOrigins:
      return await next(ctx)

    # Determine Allow-Origin value
    let originValue =
      if credentials or not allowAll: origin
      else: "*"
    let echoOrigin = originValue != "*"

    # Preflight
    if ctx.httpMethod == MethodOptions:
      var headers = HttpTable.init()
      headers.add("Access-Control-Allow-Origin", originValue)
      headers.add("Access-Control-Allow-Methods", methodsHeader)
      headers.add("Access-Control-Allow-Headers", headersHeader)
      if credentials:
        headers.add("Access-Control-Allow-Credentials", "true")
      if maxAge > 0:
        headers.add("Access-Control-Max-Age", $maxAge)
      if echoOrigin:
        headers.add("Vary", "Origin")
      return Response(code: Http204, body: "", headers: headers)

    # Normal request
    var res = await next(ctx)
    res.headers.add("Access-Control-Allow-Origin", originValue)
    if credentials:
      res.headers.add("Access-Control-Allow-Credentials", "true")
    if exposeHeader.len > 0:
      res.headers.add("Access-Control-Expose-Headers", exposeHeader)
    if echoOrigin:
      res.headers.add("Vary", "Origin")
    return res
