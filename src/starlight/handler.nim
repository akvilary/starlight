## Handler macro for generating async handler procs.
##
## Usage:
##   response homePage() -> htmlResponse:
##     Layout(ctx, title="Home", content="Hello")
##
##   response getStatus() -> jsonResponse:
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
  ## response name(params) -> htmlResponse:   last expression is string
  ## response name(params) -> jsonResponse:   last expression is JsonNode

  var nameAndParams: NimNode
  var respType: string

  if signature.kind == nnkInfix and signature[0].strVal == "->":
    nameAndParams = signature[1]
    respType = signature[2].strVal
  else:
    error("response handler must specify type: -> htmlResponse or -> jsonResponse")

  if respType notin ["htmlResponse", "jsonResponse"]:
    error("Unknown response type: " & respType &
          ". Use htmlResponse or jsonResponse.")

  let name = nameAndParams[0]

  var procBody = newStmtList()

  for binding in generateParamBindings(nameAndParams):
    procBody.add binding

  # All statements except the last are added as-is.
  # The last expression is wrapped in return response(...).
  for i in 0..<body.len - 1:
    procBody.add body[i]
  procBody.add newNimNode(nnkReturnStmt).add(
    newCall(ident"answer", body[body.len - 1]))

  # proc name*(ctx: Context): Future[Response] {.async, gcsafe.}
  let ctxParam = newIdentDefs(ident"ctx", ident"Context")
  let retType = newNimNode(nnkBracketExpr).add(ident"Future", ident"Response")

  result = newProc(
    name = postfix(name, "*"),
    params = [retType, ctxParam],
    body = procBody,
  )
  result.addPragma(ident"async")
  result.addPragma(ident"gcsafe")
