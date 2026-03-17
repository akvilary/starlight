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

proc buildHandler(nameAndParams: NimNode, body: NimNode,
                  wrapProc: string): NimNode =
  ## Shared logic for handler macro.
  ## wrapProc: "" = no wrapping, "answer" = HTML, "answerJson" = JSON
  let name = nameAndParams[0]

  var procBody = newStmtList()

  for binding in generateParamBindings(nameAndParams):
    procBody.add binding

  let transformed = transformReturns(body, wrapProc)
  for child in transformed:
    procBody.add child

  # proc name*(ctx: Context): Future[Response] {.async, gcsafe.}
  let ctxParam = newIdentDefs(ident"ctx", ident"Context")
  let retType = newNimNode(nnkBracketExpr).add(ident"Future", ident"Response")

  result = newProc(
    name = postfix(name, "*"),
    params = [retType, ctxParam],
    body = procBody,
  )
  # {.async: (raises: [CatchableError]), gcsafe.}
  result.addPragma(newNimNode(nnkExprColonExpr).add(
    ident"async",
    newNimNode(nnkTupleConstr).add(
      newNimNode(nnkExprColonExpr).add(
        ident"raises",
        newNimNode(nnkBracket).add(ident"CatchableError")
      )
    )
  ))
  result.addPragma(ident"gcsafe")

macro handler*(nameAndParams: untyped, body: untyped): untyped =
  ## Generates an async handler proc.
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
