## Handler macro for generating typed async handler procs.
##
## Usage:
##   handler home(ctx: Context) {.html.}:
##     return Page(title="Home")
##
##   handler getUser(ctx: Context, name: string) {.html.}:
##     return Page(title=name, content=UserProfile(name=name))
##
##   # Query parameters — params not matching path placeholders are auto-parsed:
##   handler search(ctx: Context, q: string, page = 1) {.json.}:
##     return %*{"q": q, "page": page}
##   # Use `= defaultValue` to make optional (type inferred from literal).
##   # Required params (no default) return Http400 if missing.
##
## Generates a proc with the exact parameters you specify:
##   proc getUser*(ctx: Context, name: string): Future[Response] {.async, gcsafe.}
##
## Direct call: await getUser(ctx, "Alice")

import std/[macros, strutils, sets]
import private/naming

const supportedQueryTypes* = toHashSet(["string", "int", "float", "bool"])

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

proc inferType(node: NimNode): NimNode =
  ## Infer type from a default value literal.
  case node.kind
  of nnkIntLit..nnkInt64Lit: ident"int"
  of nnkFloatLit..nnkFloat64Lit: ident"float"
  of nnkStrLit, nnkRStrLit, nnkTripleStrLit: ident"string"
  of nnkIdent:
    if node.strVal in ["true", "false"]: ident"bool"
    else: ident"string"
  else: ident"string"

proc buildHandler(
  nameAndParams: NimNode,
  body: NimNode,
  wrapProc: string,
  isExported: bool,
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

    case param.kind
    of nnkExprColonExpr:
      # name: Type
      formalParams.add newIdentDefs(param[0], param[1])
    of nnkIdent:
      # name (defaults to string)
      formalParams.add newIdentDefs(param, ident"string")
    of nnkExprEqExpr:
      # name = default (type inferred from literal)
      let defaultVal = param[1]
      let paramName = param[0]
      formalParams.add newIdentDefs(paramName, inferType(defaultVal), defaultVal)
    else:
      error("Unsupported parameter syntax", param)

  result = newProc(
    name = maybeExport(name, isExported),
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
  let (normalizedSig, isExported) = normalizeExportMarker(nameAndParams)
  var actualParams = normalizedSig
  var wrapProc = ""

  if normalizedSig.kind == nnkPragmaExpr:
    actualParams = normalizedSig[0]
    for pragma in normalizedSig[1]:
      if pragma.kind == nnkIdent:
        case pragma.strVal
        of "html":
          wrapProc = "answer"
        of "json":
          wrapProc = "answerJson"
        else:
          discard

  buildHandler(actualParams, body, wrapProc, isExported)

macro middleware*(nameAndParams: untyped, body: untyped): untyped =
  ## Generates a typed async middleware proc.
  ##
  ## Usage:
  ##   middleware logger(ctx: Context, next: HandlerProc):
  ##     echo ctx.path
  ##     return await next(ctx)
  let (normalizedSig, isExported) = normalizeExportMarker(nameAndParams)
  let name = normalizedSig[0]

  var procBody = newStmtList()
  for child in body:
    procBody.add child

  let retType = newNimNode(nnkBracketExpr).add(ident"Future", ident"Response")
  var formalParams: seq[NimNode] = @[retType]

  for i in 1 ..< normalizedSig.len:
    let param = normalizedSig[i]
    let (paramName, paramType) = case param.kind
      of nnkExprColonExpr: (param[0], param[1])
      else: (param, ident"Context")
    formalParams.add newIdentDefs(paramName, paramType)

  result = newProc(
    name = maybeExport(name, isExported),
    params = formalParams,
    body = procBody,
  )
  result.addPragma(makeAsyncPragma())
  result.addPragma(ident"gcsafe")

proc parsePatternParams*(pattern: string): seq[(string, string)] =
  ## Extract (name, type) pairs from a route pattern at compile time.
  ## "{name}" → ("name", "string"), "{id:int}" → ("id", "int")
  if pattern.len == 0:
    return @[]
  # Strip relative prefix "./" so "./{name}" is parsed the same as "/{name}"
  var p = pattern
  if p.startsWith("./"):
    p = p[2 .. ^1]
  let stripped = p.strip(chars = {'/'})
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

proc queryAccessor(): NimNode =
  ## Builds AST for: ctx.request.query
  newDotExpr(newDotExpr(ident"ctx", ident"request"), ident"query")

proc genConvertCall(typ: string, value: NimNode): NimNode =
  ## Builds AST for type conversion: parseInt(v), parseFloat(v), etc.
  case typ
  of "int": newCall(ident"parseInt", value)
  of "float": newCall(ident"parseFloat", value)
  of "bool": newCall(ident"parseBool", value)
  else: value

proc genQueryExtraction(
  name: string,
  typ: string,
  defaultNode: NimNode,
  stmts: NimNode,
): NimNode =
  ## Generates query parameter extraction code. Returns the variable ident.
  ## Appends extraction statements to `stmts`.
  let varIdent = ident(name)
  let query = queryAccessor()
  let keyLit = newStrLitNode(name)
  let hasRequired = defaultNode.kind == nnkEmpty

  if typ == "string":
    if hasRequired:
      # if not ctx.request.query.hasKey("name"):
      #   return errorResponse(Http400, "Missing required query parameter: name")
      # let name = ctx.request.query["name"]
      stmts.add newIfStmt((
        newCall(ident"not", newCall(ident"hasKey", query, keyLit)),
        newStmtList(newNimNode(nnkReturnStmt).add(
          newCall(ident"errorResponse", ident"Http400",
            newStrLitNode("Missing required query parameter: " & name))
        ))
      ))
      stmts.add newLetStmt(varIdent,
        newNimNode(nnkBracketExpr).add(query, keyLit))
    else:
      # let name = ctx.request.query.getOrDefault("name", default)
      stmts.add newLetStmt(varIdent,
        newCall(ident"getOrDefault", query, keyLit, defaultNode))
  else:
    # Non-string types need conversion with error handling
    let typeIdent = ident(typ)
    let rawAccessor = newNimNode(nnkBracketExpr).add(query, keyLit)
    let convertCall = genConvertCall(typ, rawAccessor)
    let errMsg = "Invalid value for query parameter: " & name

    if hasRequired:
      # if not ctx.request.query.hasKey("name"):
      #   return errorResponse(Http400, "Missing ...")
      # var name: int
      # try: name = parseInt(ctx.request.query["name"])
      # except CatchableError:
      #   return errorResponse(Http400, "Invalid ...")
      stmts.add newIfStmt((
        newCall(ident"not", newCall(ident"hasKey", query, keyLit)),
        newStmtList(newNimNode(nnkReturnStmt).add(
          newCall(ident"errorResponse", ident"Http400",
            newStrLitNode("Missing required query parameter: " & name))
        ))
      ))
      stmts.add newNimNode(nnkVarSection).add(
        newIdentDefs(varIdent, typeIdent))
      stmts.add newNimNode(nnkTryStmt).add(
        newStmtList(newAssignment(varIdent, convertCall)),
        newNimNode(nnkExceptBranch).add(
          ident"CatchableError",
          newStmtList(newNimNode(nnkReturnStmt).add(
            newCall(ident"errorResponse", ident"Http400",
              newStrLitNode(errMsg))
          ))
        )
      )
    else:
      # var name: int
      # if ctx.request.query.hasKey("name"):
      #   try: name = parseInt(ctx.request.query["name"])
      #   except CatchableError:
      #     return errorResponse(Http400, "Invalid ...")
      # else:
      #   name = defaultValue
      stmts.add newNimNode(nnkVarSection).add(
        newIdentDefs(varIdent, typeIdent))
      stmts.add newNimNode(nnkIfStmt).add(
        newNimNode(nnkElifBranch).add(
          newCall(ident"hasKey", query, keyLit),
          newStmtList(
            newNimNode(nnkTryStmt).add(
              newStmtList(newAssignment(varIdent, convertCall)),
              newNimNode(nnkExceptBranch).add(
                ident"CatchableError",
                newStmtList(newNimNode(nnkReturnStmt).add(
                  newCall(ident"errorResponse", ident"Http400",
                    newStrLitNode(errMsg))
                ))
              )
            )
          )
        ),
        newNimNode(nnkElse).add(
          newStmtList(newAssignment(varIdent, defaultNode))
        )
      )

  varIdent

macro generateHandlerWrapper*(handler: typed, pattern: static string): untyped =
  ## Generate a HandlerProc wrapper that extracts path params from ctx.pathParams
  ## and query params from ctx.request.query, with type conversion and error handling.
  ##
  ## Any handler param not matching a path param in the pattern is a query param.
  ## Required query params (no default) return Http400 if missing.
  ## Type conversion failures return Http400.
  let pathParams = parsePatternParams(pattern)
  let impl = handler.getImpl()
  let formalParams = impl[3] # nnkFormalParams

  # Collect path param names for lookup
  var pathParamNames: seq[string]
  for (name, _) in pathParams:
    pathParamNames.add name

  # Check if handler has extra params beyond ctx
  if formalParams.len <= 2 and pathParams.len == 0:
    return handler

  var stmts = newStmtList()
  var handlerCall = newCall(handler, ident"ctx")

  # Process each handler param (skip [0]=return type, [1]=ctx)
  for i in 2 ..< formalParams.len:
    let identDefs = formalParams[i]
    let pType = identDefs[identDefs.len - 2]
    let pDefault = identDefs[identDefs.len - 1]

    for j in 0 ..< identDefs.len - 2:
      let pName = identDefs[j].strVal
      let typStr = pType.strVal

      if pName in pathParamNames:
        # Path param — extract from ctx.pathParams
        let accessor = newNimNode(nnkBracketExpr).add(
          newDotExpr(ident"ctx", ident"pathParams"),
          newStrLitNode(pName)
        )
        let converted = genConvertCall(typStr, accessor)
        handlerCall.add newNimNode(nnkExprEqExpr).add(ident(pName), converted)
      else:
        # Query param — extract from ctx.request.query
        if typStr notin supportedQueryTypes:
          error("Unsupported query parameter type for '" & pName &
            "': " & typStr & ". Supported: string, int, float, bool", handler)
        let varIdent = genQueryExtraction(pName, typStr, pDefault, stmts)
        handlerCall.add newNimNode(nnkExprEqExpr).add(ident(pName), varIdent)

  stmts.add newNimNode(nnkReturnStmt).add(newCall(ident"await", handlerCall))

  let ctxParam = newIdentDefs(ident"ctx", ident"Context")
  let retType = newNimNode(nnkBracketExpr).add(ident"Future", ident"Response")

  result = newProc(
    params = [retType, ctxParam],
    body = stmts,
  )
  result.addPragma(makeAsyncPragma())
  result.addPragma(ident"gcsafe")
