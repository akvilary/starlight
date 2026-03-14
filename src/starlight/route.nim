## Route group macro.
##
## Usage:
##   proc listTags(ctx: Context): Future[Response] {.async.} =
##     result = response html:
##       h1: "Tags"
##
##   route TagsApi:
##     get "", listTags
##     get "/{id:int}", getTag

import std/macros

proc methodIdent(name: string): NimNode =
  case name
  of "get": ident"MethodGet"
  of "post": ident"MethodPost"
  of "put": ident"MethodPut"
  of "patch": ident"MethodPatch"
  of "delete": ident"MethodDelete"
  of "head": ident"MethodHead"
  of "options": ident"MethodOptions"
  else: ident"MethodGet"

macro route*(name: untyped, body: untyped): untyped =
  ## Define a route group.
  ##
  ## Each line maps an HTTP method and pattern to a handler proc:
  ##   get "/path", handlerProc
  result = newStmtList()

  # var Name = RouteGroup(entries: @[])
  result.add newVarStmt(name, newCall(ident"RouteGroup"))

  for stmt in body:
    if stmt.kind in {nnkCall, nnkCommand} and stmt[0].kind == nnkIdent:
      let httpMethodName = stmt[0].strVal
      if httpMethodName in ["get", "post", "put", "patch", "delete", "head", "options"]:
        let pattern = stmt[1]
        let handlerIdent = stmt[2]

        let entry = newNimNode(nnkObjConstr).add(
          ident"RouteEntry",
          newNimNode(nnkExprColonExpr).add(ident"httpMethod", methodIdent(httpMethodName)),
          newNimNode(nnkExprColonExpr).add(ident"pattern", pattern),
          newNimNode(nnkExprColonExpr).add(ident"handler", handlerIdent),
        )
        result.add newCall(
          newDotExpr(newDotExpr(name, ident"entries"), ident"add"),
          entry
        )
    else:
      result.add stmt
