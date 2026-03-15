## Handler macros for generating async handler procs.
##
## Usage:
##   responseHtml home():
##     return Page(title="Home")
##
##   responseJson getStatus():
##     return %*{"status": "ok"}
##
##   response custom():
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
  ## Supports: return expr  and  return expr, HttpCode
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
  ## Shared logic for all response macros.
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

macro response*(nameAndParams: untyped, body: untyped): untyped =
  ## Generates an async handler. Use return to return a Response directly.
  buildHandler(nameAndParams, body, "")

macro responseHtml*(nameAndParams: untyped, body: untyped): untyped =
  ## Generates an async handler. return expr is wrapped in answer().
  buildHandler(nameAndParams, body, "answer")

macro responseJson*(nameAndParams: untyped, body: untyped): untyped =
  ## Generates an async handler. return expr is wrapped in answerJson().
  buildHandler(nameAndParams, body, "answerJson")
