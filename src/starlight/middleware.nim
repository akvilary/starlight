## Middleware chain builder.

import types

proc buildChain*(handler: HandlerProc,
                 middlewares: seq[MiddlewareProc]): HandlerProc =
  ## Wraps handler in middleware chain (outermost middleware first).
  result = handler
  for i in countdown(middlewares.high, 0):
    let mw = middlewares[i]
    let inner = result
    result = proc(ctx: Context): Future[Response] {.
        async: (raises: [CatchableError]), gcsafe.} =
      return await mw(ctx, inner)
