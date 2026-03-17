## PrefixTree-based router with typed path parameters.

import std/[tables, options, strutils]
import types, middleware, context

proc newRouter*(): Router =
  Router(
    root: PrefixTreeNode(kind: skStatic, segment: ""),
    globalMiddlewares: @[],
    notFoundHandler: nil,
  )

proc use*(router: Router, mw: MiddlewareProc) =
  ## Adds a global middleware to the router.
  router.globalMiddlewares.add mw

proc parsePattern*(pattern: string): seq[PatternSegment] =
  let stripped = pattern.strip(chars = {'/'})
  if stripped == "":
    return @[]
  for part in stripped.split('/'):
    if part.startsWith("{") and part.endsWith("}"):
      let inner = part[1..^2]
      let colonIdx = inner.find(':')
      if colonIdx >= 0:
        let name = inner[0..<colonIdx]
        let typeStr = inner[colonIdx + 1..^1]
        let paramKind = case typeStr
          of "int": pkInt
          of "float": pkFloat
          of "bool": pkBool
          else: pkString
        result.add PatternSegment(name: name, kind: skParam, paramKind: paramKind)
      else:
        result.add PatternSegment(name: inner, kind: skParam, paramKind: pkString)
    elif part == "*":
      result.add PatternSegment(name: "", kind: skWildcard)
    else:
      result.add PatternSegment(name: part, kind: skStatic)

proc addRoute*(router: Router, httpMethod: HttpMethod, pattern: string,
               handler: HandlerProc, middlewares: seq[MiddlewareProc] = @[]) =
  let segments = parsePattern(pattern)
  var node = router.root
  for seg in segments:
    var found = false
    for child in node.children:
      if child.kind == seg.kind and child.segment == seg.name and
         (child.kind != skParam or child.paramKind == seg.paramKind):
        node = child
        found = true
        break
    if not found:
      let newNode = PrefixTreeNode(
        segment: seg.name,
        kind: seg.kind,
        paramKind: seg.paramKind,
      )
      node.children.add newNode
      node = newNode
  node.handlers[httpMethod] = HandlerEntry(
    handler: handler,
    middlewares: middlewares,
  )

proc mount*(router: Router, prefix: string, group: RouteGroup,
            middlewares: seq[MiddlewareProc] = @[]) =
  ## Mounts a route group at the given prefix.
  ## Optional middlewares are prepended to each route's middleware chain.
  for entry in group.entries:
    let fullPattern = if prefix == "/": entry.pattern
                      elif entry.pattern == "": prefix
                      else: prefix & entry.pattern
    router.addRoute(entry.httpMethod, fullPattern,
                    entry.handler, middlewares & entry.middlewares)

proc validateParam(value: string, kind: ParamKind): bool =
  case kind
  of pkString: true
  of pkInt:
    try: discard parseInt(value); true
    except: false
  of pkFloat:
    try: discard parseFloat(value); true
    except: false
  of pkBool:
    value in ["true", "false", "1", "0"]

proc match*(router: Router, httpMethod: HttpMethod, path: string): Option[MatchResult] =
  let stripped = path.strip(chars = {'/'})
  let segments = if stripped == "": @[] else: stripped.split('/')
  var params: Table[string, string] = initTable[string, string]()

  proc matchRec(node: PrefixTreeNode, idx: int): Option[PrefixTreeNode] =
    if idx >= segments.len:
      if httpMethod in node.handlers:
        return some(node)
      return none(PrefixTreeNode)

    let seg = segments[idx]

    # Static children first (most specific)
    for child in node.children:
      if child.kind == skStatic and child.segment == seg:
        let r = matchRec(child, idx + 1)
        if r.isSome: return r

    # Param children
    for child in node.children:
      if child.kind == skParam and validateParam(seg, child.paramKind):
        params[child.segment] = seg
        let r = matchRec(child, idx + 1)
        if r.isSome: return r
        params.del(child.segment)

    # Wildcard children
    for child in node.children:
      if child.kind == skWildcard:
        let r = matchRec(child, idx + 1)
        if r.isSome: return r

    return none(PrefixTreeNode)

  let matched = matchRec(router.root, 0)
  if matched.isSome:
    let node = matched.get
    try:
      let entry = node.handlers[httpMethod]
      return some(MatchResult(
        handler: entry.handler,
        params: params,
        middlewares: entry.middlewares,
      ))
    except KeyError:
      discard
  return none(MatchResult)

proc resolvePath*(currentPath, target: string): string =
  ## Resolves a target path relative to the current path.
  ## Absolute paths (starting with /) are returned as-is.
  ## Relative paths (./ and ../) are resolved against currentPath.
  if target.startsWith("/"):
    return target
  var segments = currentPath.strip(chars = {'/'}).split('/')
  if segments == @[""]:
    segments = @[]
  for part in target.split('/'):
    case part
    of "..":
      if segments.len > 0: segments.setLen(segments.len - 1)
    of ".": discard
    else: segments.add(part)
  "/" & segments.join("/")

proc dispatch*(router: Router, ctx: Context): Future[Response] {.
    async: (raises: [CatchableError]).} =
  ## Dispatches a context through the router with full middleware chain.
  let matched = router.match(ctx.httpMethod, ctx.path)
  if matched.isSome:
    let m = matched.get
    ctx.pathParams = m.params
    let allMw = router.globalMiddlewares & m.middlewares
    let chain = buildChain(m.handler, allMw)
    return await chain(ctx)
  elif router.notFoundHandler != nil:
    return await router.notFoundHandler(ctx)
  else:
    return Response(code: Http404, body: "Not Found",
                    headers: HttpTable.init([("Content-Type", "text/plain")]))

proc prepareForward(ctx: Context, httpMethod: HttpMethod,
                    path: string): Context =
  ## Creates a cloned context for internal dispatch.
  var newCtx = ctx.clone()
  newCtx.path = resolvePath(ctx.path, path)
  newCtx.httpMethod = httpMethod
  newCtx

proc forward*(ctx: Context,
              httpMethod: HttpMethod, path: string): Future[Response] {.
    async: (raises: [CatchableError]).} =
  ## Dispatches an internal request through the router.
  ## Creates a cloned context — the original ctx is not modified.
  ## Supports absolute (/path) and relative (./path, ../path) paths.
  let newCtx = prepareForward(ctx, httpMethod, path)
  return await ctx.router.dispatch(newCtx)

proc forward*(ctx: Context,
              httpMethod: HttpMethod, path: string,
              query: Table[string, string]): Future[Response] {.
    async: (raises: [CatchableError]).} =
  ## Dispatches an internal request with custom query parameters.
  ## Creates a new RequestData with the given query — the original ctx is not modified.
  var newCtx = prepareForward(ctx, httpMethod, path)
  newCtx.request = RequestData(
    headers: ctx.request.headers,
    body: ctx.request.body,
    query: query,
    ip: ctx.request.ip,
  )
  return await ctx.router.dispatch(newCtx)
