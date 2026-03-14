## Handler macro for generating async handler procs.
##
## Usage:
##   response home() -> ofHtml:
##     Page(title="Home")
##
##   response getStatus() -> ofJson:
##     %*{"status": "ok"}

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

macro response*(signature: untyped, body: untyped): untyped =
  ## Generates an async handler proc returning Future[Response].
  ##
  ## response name(params) -> ofHtml:   last expression wrapped in answer()
  ## response name(params) -> ofJson:   last expression wrapped in answerJson()

  var nameAndParams: NimNode
  var respType: string

  if signature.kind == nnkInfix and signature[0].strVal == "->":
    nameAndParams = signature[1]
    respType = signature[2].strVal
  else:
    error("response handler must specify type: -> ofhtml or -> ofjson")

  if respType notin ["ofHtml", "ofJson"]:
    error("Unknown response type: " & respType &
          ". Use ofHtml or ofJson.")

  let name = nameAndParams[0]
  let answerProc = if respType == "ofJson": ident"answerJson"
                   else: ident"answer"

  var procBody = newStmtList()

  for binding in generateParamBindings(nameAndParams):
    procBody.add binding

  # All statements except the last are added as-is.
  # The last expression is wrapped in return answer/answerJson(...).
  for i in 0..<body.len - 1:
    procBody.add body[i]
  procBody.add newNimNode(nnkReturnStmt).add(
    newCall(answerProc, body[body.len - 1]))

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
