## HTTP server adapter using chronos.

import std/[tables, options, strutils, uri]
import chronos
import chronos/apps/http/httpserver
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

proc newContextFromRequest(req: HttpRequestRef): Context =
  let ctx = newContext()
  let fullPath = req.rawPath
  let qIdx = fullPath.find('?')
  if qIdx >= 0:
    ctx.path = fullPath[0..<qIdx]
    ctx.query = parseQueryString(fullPath[qIdx + 1..^1])
  else:
    ctx.path = fullPath
  ctx.httpMethod = req.meth
  ctx.headers = req.headers
  ctx.ip = try:
    $req.remote().get()
  except:
    ""
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
  for entry in group.entries:
    let fullPattern = if prefix == "/": entry.pattern
                      elif entry.pattern == "": prefix
                      else: prefix & entry.pattern
    app.router.addRoute(entry.httpMethod, fullPattern,
                        entry.handler, entry.middlewares)

proc finalizeResponse(res: var Response) =
  if res.code == HttpCode(0):
    res.code = Http200

proc serve*(app: App, host: string, port: int) =
  proc onRequest(reqFence: RequestFence): Future[HttpResponseRef] {.
      async: (raises: [CancelledError]).} =
    if reqFence.isErr():
      return defaultResponse()

    let req = reqFence.get()
    var ctx = newContextFromRequest(req)

    # Read body for POST/PUT/PATCH
    if req.hasBody():
      try:
        let bodyBytes = await req.getBody()
        ctx.body = cast[string](bodyBytes)
      except CancelledError as exc:
        raise exc
      except CatchableError:
        ctx.body = ""

    var res: Response

    let matched = app.router.match(ctx.httpMethod, ctx.path)
    if matched.isSome:
      let m = matched.get
      ctx.pathParams = m.params
      let allMw = app.globalMiddlewares & m.middlewares
      let chain = buildChain(m.handler, allMw)
      try:
        res = await chain(ctx)
      except CancelledError as exc:
        raise exc
      except CatchableError:
        res = Response(code: Http500, body: "Internal Server Error",
                       headers: HttpTable.init([("Content-Type", "text/plain")]))
    else:
      if app.notFoundHandler != nil:
        try:
          res = await app.notFoundHandler(ctx)
        except CancelledError as exc:
          raise exc
        except CatchableError:
          res = Response(code: Http500, body: "Internal Server Error",
                         headers: HttpTable.init([("Content-Type", "text/plain")]))
      else:
        res = Response(code: Http404, body: "Not Found",
                       headers: HttpTable.init([("Content-Type", "text/plain")]))

    finalizeResponse(res)

    try:
      return await req.respond(res.code, res.body, res.headers)
    except HttpWriteError:
      return defaultResponse()

  let address = initTAddress(host, port)
  let cb: HttpProcessCallback2 = onRequest
  let serverResult = HttpServerRef.new(address, cb)

  if serverResult.isErr():
    echo "Failed to start server: ", serverResult.error()
    return

  let server = serverResult.get()
  server.start()
  echo "Starlight listening on http://", host, ":", port
  waitFor server.join()
