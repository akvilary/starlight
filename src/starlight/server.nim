## HTTP server adapter using chronos.

import std/[tables, options, strutils]
import chronos
import chronos/apps/http/httpserver
import types, router, context, form

proc newContextFromRequest(req: HttpRequestRef): Context =
  let ctx = newContext()
  let fullPath = req.rawPath
  let qIdx = fullPath.find('?')
  if qIdx >= 0:
    ctx.path = fullPath[0..<qIdx]
    ctx.request.query = parseQueryString(fullPath[qIdx + 1..^1])
  else:
    ctx.path = fullPath
  ctx.httpMethod = req.meth
  ctx.request.headers = req.headers
  ctx.request.ip = try:
    $req.remote().get()
  except:
    ""
  ctx

proc finalizeResponse(res: var Response) =
  if res.code == HttpCode(0):
    res.code = Http200

proc serve*(router: Router, host: string, port: int) =
  proc onRequest(
    reqFence: RequestFence,
  ): Future[HttpResponseRef] {.async: (raises: [CancelledError]).} =
    if reqFence.isErr():
      return defaultResponse()

    let req = reqFence.get()
    var ctx = newContextFromRequest(req)

    # Read body for POST/PUT/PATCH
    if req.hasBody():
      try:
        let bodyBytes = await req.getBody()
        ctx.request.body = cast[string](bodyBytes)
      except CancelledError as exc:
        raise exc
      except CatchableError:
        ctx.request.body = ""

    ctx.router = router

    var res: Response

    try:
      res = await router.dispatch(ctx)
    except CancelledError as exc:
      raise exc
    except CatchableError:
      try:
        res = await router.resolveError(ctx, Http500, "Internal Server Error")
      except CancelledError as exc:
        raise exc
      except CatchableError:
        res = errorResponse(Http500, "Internal Server Error")

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
