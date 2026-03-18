## Middleware chain builder and built-in middleware helpers.

import types

proc buildChain*(
  handler: HandlerProc,
  middlewares: seq[MiddlewareProc],
): HandlerProc =
  ## Wraps handler in middleware chain (outermost middleware first).
  result = handler
  for i in countdown(middlewares.high, 0):
    let mw = middlewares[i]
    let inner = result
    result = proc(ctx: Context): Future[Response] {.
        async: (raises: [CatchableError]), gcsafe.} =
      return await mw(ctx, inner)

# --- Built-in middleware ---

proc withTimeout*(ms: int): MiddlewareProc =
  ## Returns a middleware that aborts the handler after `ms` milliseconds
  ## with Http408 Request Timeout.
  return proc(ctx: Context, next: HandlerProc): Future[Response] {.
      async: (raises: [CatchableError]), gcsafe.} =
    try:
      return await next(ctx).wait(milliseconds(ms))
    except AsyncTimeoutError:
      return Response(code: Http408, body: "Request Timeout",
                      headers: HttpTable.init([("Content-Type", "text/plain")]))
