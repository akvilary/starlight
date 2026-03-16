## Route group macro.
##
## Usage:
##   handler listTags() {.html.}:
##     return renderTags()
##
##   route TagsApi:
##     get("", listTags)
##     get("/{id:int}", getTag)
##
##   # Or with inline body:
##   route Main:
##     get("/"):
##       return answer("Hello")

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

proc makeHandlerProc(name, body: NimNode): NimNode =
  let asyncPragma = newNimNode(nnkExprColonExpr).add(
    ident"async",
    newNimNode(nnkTupleConstr).add(
      newNimNode(nnkExprColonExpr).add(
        ident"raises",
        newNimNode(nnkBracket).add(ident"CatchableError")
      )
    )
  )
  let pragmas = newNimNode(nnkPragma).add(asyncPragma, ident"gcsafe")
  let params = newNimNode(nnkFormalParams).add(
    newNimNode(nnkBracketExpr).add(ident"Future", ident"Response"),
    newIdentDefs(ident"ctx", ident"Context")
  )
  result = newNimNode(nnkProcDef).add(
    name,
    newEmptyNode(),
    newEmptyNode(),
    params,
    pragmas,
    newEmptyNode(),
    body
  )

const httpMethods = ["get", "post", "put", "patch", "delete", "head", "options"]

macro route*(name: untyped, body: untyped): untyped =
  ## Define a route group.
  ##
  ## Supported syntaxes:
  ##   get("/path", handlerProc)
  ##   get("/path"):
  ##     ...inline body...
  result = newStmtList()

  # var Name = RouteGroup(entries: @[])
  result.add newVarStmt(name, newCall(ident"RouteGroup"))

  for stmt in body:
    if stmt.kind == nnkCall and stmt[0].kind == nnkIdent:
      let httpMethodName = stmt[0].strVal
      if httpMethodName in httpMethods:
        var handlerIdent: NimNode
        let pattern = stmt[1]

        if stmt.len == 3 and stmt[2].kind == nnkStmtList:
          # Inline body: get("/path"):
          #   ...body...
          handlerIdent = genSym(nskProc, "handler")
          result.add makeHandlerProc(handlerIdent, stmt[2])
        elif stmt.len == 3:
          # Reference: get("/path", handlerProc)
          handlerIdent = stmt[2]
        else:
          error(
            "Invalid route syntax. Use " &
            httpMethodName & "(\"path\", handler) or " &
            httpMethodName & "(\"path\"): body",
            stmt
          )

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
    else:
      result.add stmt
