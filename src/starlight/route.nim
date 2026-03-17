## Route group macro.
##
## Usage:
##   route UsersApi:
##     get("/{name}", getUser)
##     get("/{name}", getUser, middleware = [authMiddleware])
##
##   # Or with inline body:
##   route Main:
##     get("/"):
##       return answer("Hello")

import std/macros
import handler

proc makeHandlerProc(name, body: NimNode): NimNode =
  let pragmas = newNimNode(nnkPragma).add(makeAsyncPragma(), ident"gcsafe")
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
  ##   get("/path", handlerProc, middleware = [mw1, mw2])
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

        var middlewaresNode = newNimNode(nnkPrefix).add(ident"@",
          newNimNode(nnkBracket))

        var isInline = false

        if stmt.len == 3 and stmt[2].kind == nnkStmtList:
          # Inline body: get("/path"):
          #   ...body...
          handlerIdent = genSym(nskProc, "handler")
          result.add makeHandlerProc(handlerIdent, stmt[2])
          isInline = true
        elif stmt.len == 3:
          # Reference: get("/path", handlerProc)
          handlerIdent = stmt[2]
        elif stmt.len == 4:
          # Reference with middleware:
          #   get("/path", handler, middleware = [mw1])
          #   get("/path", handler, @[mw1])
          handlerIdent = stmt[2]
          if stmt[3].kind == nnkExprEqExpr and stmt[3][0].eqIdent("middleware"):
            let mwList = stmt[3][1]
            middlewaresNode = newNimNode(nnkPrefix).add(ident"@", mwList)
          else:
            middlewaresNode = stmt[3]
        else:
          error(
            "Invalid route syntax. Use " &
            httpMethodName & "(\"path\", handler) or " &
            httpMethodName & "(\"path\", handler, middleware = [mw])",
            stmt
          )

        # For inline handlers, use directly; for typed handlers, wrap with pattern
        let handlerValue = if isInline:
          handlerIdent
        else:
          generateHandlerWrapper(handlerIdent, pattern.strVal)

        let entry = newNimNode(nnkObjConstr).add(
          ident"RouteEntry",
          newNimNode(nnkExprColonExpr).add(ident"httpMethod", methodIdent(httpMethodName)),
          newNimNode(nnkExprColonExpr).add(ident"pattern", pattern),
          newNimNode(nnkExprColonExpr).add(ident"handler", handlerValue),
          newNimNode(nnkExprColonExpr).add(ident"middlewares", middlewaresNode),
        )
        result.add newCall(
          newDotExpr(newDotExpr(name, ident"entries"), ident"add"),
          entry
        )
      else:
        result.add stmt
    else:
      result.add stmt
