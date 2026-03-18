## Handler macro for generating typed async handler procs.
##
## Usage:
##   handler home(ctx: Context) {.html.}:
##     return Page(title="Home")
##
##   handler getUser(ctx: Context, name: string) {.html.}:
##     return Page(title=name, content=UserProfile(name=name))
##
## Generates a proc with the exact parameters you specify:
##   proc getUser*(ctx: Context, name: string): Future[Response] {.async, gcsafe.}
##
## Direct call: await getUser(ctx, "Alice")

import std/[macros, strutils]

proc makeAsyncPragma*(): NimNode =
  ## Builds the {.async: (raises: [CatchableError]).} pragma node.
  newNimNode(nnkExprColonExpr).add(
    ident"async",
    newNimNode(nnkTupleConstr).add(
      newNimNode(nnkExprColonExpr).add(
        ident"raises",
        newNimNode(nnkBracket).add(ident"CatchableError")
      )
    )
  )

proc methodIdent*(name: string): NimNode =
  ## Converts a lowercase HTTP method name to the Chronos enum ident.
  case name
  of "get": ident"MethodGet"
  of "post": ident"MethodPost"
  of "put": ident"MethodPut"
  of "patch": ident"MethodPatch"
  of "delete": ident"MethodDelete"
  of "head": ident"MethodHead"
  of "options": ident"MethodOptions"
  else: ident"MethodGet"

proc transformReturns(node: NimNode, wrapProc: string): NimNode =
  ## Recursively walks the AST and wraps return expressions
  ## with wrapProc (answer/answerJson). Empty wrapProc = no wrapping.
  ## Supports: return expr  and  return (expr, HttpCode)
  if node.kind == nnkReturnStmt and node[0].kind != nnkEmpty:
    if wrapProc.len == 0:
      return node
    let retExpr = node[0]
    var call = newCall(ident(wrapProc))
    if retExpr.kind == nnkTupleConstr:
      for child in retExpr:
        call.add child
    else:
      call.add retExpr
    return newNimNode(nnkReturnStmt).add(call)

  result = node.copyNimNode()
  for child in node:
    result.add transformReturns(child, wrapProc)

proc buildHandler(
    nameAndParams: NimNode,
    body: NimNode,
    wrapProc: string,
): NimNode =
  ## Generates the typed async handler proc.
  let name = nameAndParams[0]

  let transformed = transformReturns(body, wrapProc)
  var procBody = newStmtList()
  for child in transformed:
    procBody.add child

  # Build params: (Future[Response], param1: type1, ...)
  let retType = newNimNode(nnkBracketExpr).add(ident"Future", ident"Response")
  var formalParams: seq[NimNode] = @[retType]

  for i in 1..<nameAndParams.len:
    let param = nameAndParams[i]
    var paramName, paramType: NimNode

    case param.kind
    of nnkExprColonExpr:
      paramName = param[0]
      paramType = param[1]
    of nnkIdent:
      paramName = param
      paramType = ident"string"
    else:
      paramName = param[0]
      paramType = ident"string"

    formalParams.add newIdentDefs(paramName, paramType)

  result = newProc(
    name = postfix(name, "*"),
    params = formalParams,
    body = procBody,
  )
  result.addPragma(makeAsyncPragma())
  result.addPragma(ident"gcsafe")

macro handler*(nameAndParams: untyped, body: untyped): untyped =
  ## Generates a typed async handler proc.
  ##
  ## Pragmas:
  ##   {.html.} — wraps return in answer() (Content-Type: text/html)
  ##   {.json.} — wraps return in answerJson() (Content-Type: application/json)
  ##   (none)   — no wrapping, return must be a Response
  var actualParams = nameAndParams
  var wrapProc = ""

  if nameAndParams.kind == nnkPragmaExpr:
    actualParams = nameAndParams[0]
    for pragma in nameAndParams[1]:
      if pragma.kind == nnkIdent:
        case pragma.strVal
        of "html":
          wrapProc = "answer"
        of "json":
          wrapProc = "answerJson"
        else:
          discard

  buildHandler(actualParams, body, wrapProc)

proc parsePatternParams*(pattern: string): seq[(string, string)] =
  ## Extract (name, type) pairs from a route pattern at compile time.
  ## "{name}" → ("name", "string"), "{id:int}" → ("id", "int")
  if pattern.len == 0:
    return @[]
  let stripped = pattern.strip(chars = {'/'})
  if stripped.len == 0:
    return @[]
  for part in stripped.split('/'):
    if part.startsWith("{") and part.endsWith("}"):
      let inner = part[1..^2]
      let colonIdx = inner.find(':')
      if colonIdx >= 0:
        result.add((inner[0..<colonIdx], inner[colonIdx + 1..^1]))
      else:
        result.add((inner, "string"))

proc generateHandlerWrapper*(handler: NimNode, pattern: string): NimNode =
  ## Generate a HandlerProc wrapper that extracts path params from ctx.pathParams
  ## and calls the typed handler proc with named arguments.
  ##
  ## Used by route groups and router.add at compile time.
  let params = parsePatternParams(pattern)

  if params.len == 0:
    return handler

  # Build call: await handler(ctx, name=ctx.pathParams["name"], ...)
  var handlerCall = newCall(handler, ident"ctx")

  for (name, typ) in params:
    let accessor = newNimNode(nnkBracketExpr).add(
      newDotExpr(ident"ctx", ident"pathParams"),
      newStrLitNode(name)
    )

    let converted = case typ
      of "int": newCall(ident"parseInt", accessor)
      of "float": newCall(ident"parseFloat", accessor)
      of "bool": newCall(ident"parseBool", accessor)
      else: accessor

    handlerCall.add newNimNode(nnkExprEqExpr).add(ident(name), converted)

  let body = newStmtList(
    newNimNode(nnkReturnStmt).add(newCall(ident"await", handlerCall))
  )

  let ctxParam = newIdentDefs(ident"ctx", ident"Context")
  let retType = newNimNode(nnkBracketExpr).add(ident"Future", ident"Response")

  result = newProc(
    params = [retType, ctxParam],
    body = body,
  )
  result.addPragma(makeAsyncPragma())
  result.addPragma(ident"gcsafe")
