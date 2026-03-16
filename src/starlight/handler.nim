## Handler macro for generating async handler procs.
##
## Usage:
##   handler home() {.html.}:
##     return Page(title="Home")
##
##   handler getStatus() {.json.}:
##     return %*{"status": "ok"}
##
##   handler custom():
##     return answer("hello", Http200)

import std/macros

proc generateParamBindings(nameAndParams: NimNode): seq[NimNode] =
  for i in 1..<nameAndParams.len:
    let param = nameAndParams[i]
    var paramName: NimNode
    var paramType = "string"

    case param.kind
    of nnkExprColonExpr:
      paramName = param[0]
      paramType = param[1].strVal
    of nnkIdent:
      paramName = param
    else:
      paramName = param[0]

    let accessor = newNimNode(nnkBracketExpr).add(
      newDotExpr(ident"ctx", ident"pathParams"),
      newStrLitNode(paramName.strVal)
    )

    case paramType
    of "int":
      result.add newLetStmt(paramName, newCall(ident"parseInt", accessor))
    of "float":
      result.add newLetStmt(paramName, newCall(ident"parseFloat", accessor))
    of "bool":
      result.add newLetStmt(paramName, newCall(ident"parseBool", accessor))
    else:
      result.add newLetStmt(paramName, accessor)

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

proc addAsyncGcsafePragmas(node: NimNode) =
  ## Adds {.async: (raises: [CatchableError]), gcsafe.} pragmas to a proc.
  node.addPragma(newNimNode(nnkExprColonExpr).add(
    ident"async",
    newNimNode(nnkTupleConstr).add(
      newNimNode(nnkExprColonExpr).add(
        ident"raises",
        newNimNode(nnkBracket).add(ident"CatchableError")
      )
    )
  ))
  node.addPragma(ident"gcsafe")

proc buildHandler(nameAndParams: NimNode, body: NimNode,
                  wrapProc: string, timeoutMs: int = 0): NimNode =
  ## Shared logic for handler macro.
  ## wrapProc: "" = no wrapping, "answer" = HTML, "answerJson" = JSON
  ## timeoutMs: 0 = no timeout, >0 = timeout in milliseconds
  let name = nameAndParams[0]

  # Build the core body (param bindings + transformed returns)
  var coreBody = newStmtList()
  for binding in generateParamBindings(nameAndParams):
    coreBody.add binding
  let transformed = transformReturns(body, wrapProc)
  for child in transformed:
    coreBody.add child

  var procBody: NimNode

  if timeoutMs > 0:
    procBody = newStmtList()

    # proc __inner__(ctx: Context): Future[Response] {.async, gcsafe, nimcall.}
    let innerProc = newProc(
      name = ident"__inner__",
      params = [
        newNimNode(nnkBracketExpr).add(ident"Future", ident"Response"),
        newIdentDefs(ident"ctx", ident"Context"),
      ],
      body = coreBody,
    )
    innerProc.addAsyncGcsafePragmas()
    innerProc.addPragma(ident"nimcall")
    procBody.add innerProc

    # return await __inner__(ctx).wait(milliseconds(N))
    let waitCall = newCall(
      newDotExpr(
        newCall(ident"__inner__", ident"ctx"),
        ident"wait",
      ),
      newCall(ident"milliseconds", newIntLitNode(timeoutMs)),
    )
    let returnAwait = newNimNode(nnkReturnStmt).add(
      newCall(ident"await", waitCall)
    )

    # Response(code: Http408, body: "Request Timeout", headers: ...)
    let timeoutResponse = newNimNode(nnkObjConstr).add(
      ident"Response",
      newNimNode(nnkExprColonExpr).add(ident"code", ident"Http408"),
      newNimNode(nnkExprColonExpr).add(ident"body", newStrLitNode("Request Timeout")),
      newNimNode(nnkExprColonExpr).add(
        ident"headers",
        newCall(
          newDotExpr(ident"HttpTable", ident"init"),
          newNimNode(nnkBracket).add(
            newNimNode(nnkTupleConstr).add(
              newStrLitNode("Content-Type"),
              newStrLitNode("text/plain"),
            )
          ),
        ),
      ),
    )

    # try: ... except AsyncTimeoutError: ...
    procBody.add newNimNode(nnkTryStmt).add(
      newStmtList(returnAwait),
      newNimNode(nnkExceptBranch).add(
        ident"AsyncTimeoutError",
        newStmtList(newNimNode(nnkReturnStmt).add(timeoutResponse)),
      ),
    )
  else:
    procBody = coreBody

  # proc name*(ctx: Context): Future[Response] {.async, gcsafe.}
  let ctxParam = newIdentDefs(ident"ctx", ident"Context")
  let retType = newNimNode(nnkBracketExpr).add(ident"Future", ident"Response")

  result = newProc(
    name = postfix(name, "*"),
    params = [retType, ctxParam],
    body = procBody,
  )
  result.addAsyncGcsafePragmas()

macro handler*(nameAndParams: untyped, body: untyped): untyped =
  ## Generates an async handler proc.
  ##
  ## Pragmas:
  ##   {.html.}         — wraps return in answer() (Content-Type: text/html)
  ##   {.json.}         — wraps return in answerJson() (Content-Type: application/json)
  ##   {.timeout: N.}   — aborts handler after N ms with 408 Request Timeout
  ##   (none)           — no wrapping, return must be a Response
  var actualParams = nameAndParams
  var wrapProc = ""
  var timeoutMs = 0

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
      elif pragma.kind == nnkExprColonExpr:
        if pragma[0].kind == nnkIdent and pragma[0].strVal == "timeout":
          if pragma[1].kind in {nnkIntLit..nnkUInt64Lit}:
            timeoutMs = pragma[1].intVal.int

  buildHandler(actualParams, body, wrapProc, timeoutMs)
