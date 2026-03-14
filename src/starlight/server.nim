## HTTP server adapter using httpx.

import std/[asyncdispatch, httpcore, tables, options, strutils, uri]
import httpx except Settings
import types, router, middleware, context

proc parseQueryString(qs: string): Table[string, string] =
  result = initTable[string, string]()
  if qs.len == 0: return
  for pair in qs.split('&'):
    let eqIdx = pair.find('=')
    if eqIdx >= 0:
      result[decodeUrl(pair[0..<eqIdx])] = decodeUrl(pair[eqIdx + 1..^1])
    else:
      result[decodeUrl(pair)] = ""

proc formatResponseHeaders(headers: HttpHeaders): string =
  result = ""
  if headers == nil: return
  for key, val in headers:
    if result.len > 0:
      result.add "\c\L"
    result.add key & ": " & val

proc newContextFromRequest(req: httpx.Request): Context =
  let ctx = newContext()
  let fullPath = req.path.get("/")
  let qIdx = fullPath.find('?')
  if qIdx >= 0:
    ctx.path = fullPath[0..<qIdx]
    ctx.query = parseQueryString(fullPath[qIdx + 1..^1])
  else:
    ctx.path = fullPath
  ctx.httpMethod = req.httpMethod.get(HttpGet)
  let reqHeaders = req.headers
  if reqHeaders.isSome:
    ctx.headers = reqHeaders.get
  ctx.body = req.body.get("")
  ctx.ip = req.ip
  ctx

proc newApp*(): App =
  App(
    router: newRouter(),
    globalMiddlewares: @[],
    notFoundHandler: nil,
  )

proc use*(app: App, mw: MiddlewareProc) =
  app.globalMiddlewares.add mw

proc mount*(app: App, prefix: string, group: RouteGroup) =
  ## Mount a route group at the given prefix.
  for entry in group.entries:
    let fullPattern = if prefix == "/": entry.pattern
                      elif entry.pattern == "": prefix
                      else: prefix & entry.pattern
    app.router.addRoute(entry.httpMethod, fullPattern,
                        entry.handler, entry.middlewares)

proc finalizeResponse(res: var Response) =
  ## Apply defaults to a Response before sending.
  # Default status code to 200
  if res.code == HttpCode(0):
    res.code = Http200

  # Ensure headers exist
  if res.headers == nil:
    res.headers = newHttpHeaders()

  # Default Content-Type to text/html for non-empty body
  if not res.headers.hasKey("Content-Type") and res.body.len > 0:
    res.headers["Content-Type"] = "text/html; charset=utf-8"

proc serve*(app: App, host: string, port: int) =
  let settings = httpx.initSettings(Port(port), host)

  proc onRequest(req: httpx.Request): Future[void] {.async, gcsafe.} =
    if req.closed: return
    var ctx = newContextFromRequest(req)
    var res: Response

    let matched = app.router.match(ctx.httpMethod, ctx.path)
    if matched.isSome:
      let m = matched.get
      ctx.pathParams = m.params
      let allMw = app.globalMiddlewares & m.middlewares
      let chain = buildChain(m.handler, allMw)
      try:
        res = await chain(ctx)
      except CatchableError:
        res = Response(code: Http500, body: "Internal Server Error",
                       
headers: newHttpHeaders({"Content-Type": "text/plain"}))
    else:
      if app.notFoundHandler != nil:
        try:
          res = await app.notFoundHandler(ctx)
        except CatchableError:
          res = Response(code: Http500, body: "Internal Server Error",
                         
  headers: newHttpHeaders({"Content-Type": "text/plain"}))
      else:
        res = Response(code: Http404, body: "Not Found",
                       
headers: newHttpHeaders({"Content-Type": "text/plain"}))

    finalizeResponse(res)

    let respHeaders = formatResponseHeaders(res.headers)
    req.send(res.code, res.body, respHeaders)

  echo "Starlight listening on http://", host, ":", port
  httpx.run(onRequest, settings)
