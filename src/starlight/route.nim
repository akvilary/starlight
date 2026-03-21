## Route group macro and Route entity constructor.
##
## Usage:
##   route UsersApi:
##     get("/{name}", getUser)
##     get("/{name}", getUser, middleware = @[authMiddleware])
##     add(userRoute)
##
##   # Or with inline body:
##   route Main:
##     get("/"):
##       return answer("Hello")
##
##   # Route entity:
##   let userShow = newRoute(MethodGet, "/users/{name}", getUser)
##   let protectedUser = newRoute(MethodGet, "/admin/{name}", getUser, middleware = @[auth])

import std/[macros, strutils]
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

proc castMiddlewares(mwExpr: NimNode): NimNode =
  ## Wraps each element of @[mw1, mw2] in MiddlewareProc() to fix
  ## nimcall→closure calling convention. Passes other expressions through.
  if mwExpr.kind == nnkPrefix and mwExpr[0].eqIdent("@") and
     mwExpr[1].kind == nnkBracket:
    var bracket = newNimNode(nnkBracket)
    for mw in mwExpr[1]:
      bracket.add newCall(ident"MiddlewareProc", mw)
    result = newNimNode(nnkPrefix).add(ident"@", bracket)
  else:
    result = mwExpr

const httpMethods = ["get", "post", "put", "patch", "delete", "head", "options"]

macro newRoute*(
  httpMethod: untyped,
  pattern: static string,
  handler: untyped,
): untyped =
  ## Creates a RouteRef wrapping a RouteEntry, with the pattern baked into the type.
  ##
  ## The handler is wrapped to extract path and query parameters automatically.
  ## The resulting type RouteRef[pattern] enables compile-time URL generation via urlFor.
  let wrapped = newCall(ident"generateHandlerWrapper", handler, newStrLitNode(pattern))
  let refType = newNimNode(nnkBracketExpr).add(
    ident"RouteRef", newStrLitNode(pattern))
  let entryExpr = newNimNode(nnkObjConstr).add(
    ident"RouteEntry",
    newNimNode(nnkExprColonExpr).add(ident"httpMethod", httpMethod),
    newNimNode(nnkExprColonExpr).add(ident"pattern", newStrLitNode(pattern)),
    newNimNode(nnkExprColonExpr).add(ident"handler", wrapped),
  )
  result = newNimNode(nnkObjConstr).add(
    refType, newNimNode(nnkExprColonExpr).add(ident"entry", entryExpr))

macro newRoute*(
  httpMethod: untyped,
  pattern: static string,
  handler: untyped,
  middleware: untyped,
): untyped =
  ## Creates a RouteRef with middleware.
  let wrapped = newCall(ident"generateHandlerWrapper", handler, newStrLitNode(pattern))
  let refType = newNimNode(nnkBracketExpr).add(
    ident"RouteRef", newStrLitNode(pattern))
  let entryExpr = newNimNode(nnkObjConstr).add(
    ident"RouteEntry",
    newNimNode(nnkExprColonExpr).add(ident"httpMethod", httpMethod),
    newNimNode(nnkExprColonExpr).add(ident"pattern", newStrLitNode(pattern)),
    newNimNode(nnkExprColonExpr).add(ident"handler", wrapped),
    newNimNode(nnkExprColonExpr).add(
      ident"middlewares", castMiddlewares(middleware)),
  )
  result = newNimNode(nnkObjConstr).add(
    refType, newNimNode(nnkExprColonExpr).add(ident"entry", entryExpr))

macro route*(name: untyped, body: untyped): untyped =
  ## Define a route group.
  ##
  ## Supported syntaxes:
  ##   get("/path", handlerProc)
  ##   get("/path", handlerProc, middleware = @[mw1, mw2])
  ##   get("/path"):
  ##     ...inline body...
  ##   add(routeRef)
  result = newStmtList()

  # var Name = RouteGroup(entries: @[])
  result.add newVarStmt(name, newCall(ident"RouteGroup"))

  for stmt in body:
    if stmt.kind == nnkCall and stmt[0].kind == nnkIdent:
      let methodName = stmt[0].strVal

      if methodName == "add":
        # add(routeRef) — adds the RouteRef's entry to the group
        let routeVar = stmt[1]
        result.add newCall(
          newDotExpr(newDotExpr(name, ident"entries"), ident"add"),
          newDotExpr(routeVar, ident"entry"),
        )

      elif methodName in httpMethods:
        var handlerIdent: NimNode
        let pattern = stmt[1]

        # Route group patterns must be relative (start with "./")
        if pattern.kind == nnkStrLit and not pattern.strVal.startsWith("./"):
          error(
            "Route group patterns must be relative (start with \"./\"). " &
            "Got: \"" & pattern.strVal & "\". " &
            "Use: \"./" & pattern.strVal.strip(chars = {'/'}) & "\"",
            stmt,
          )

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
          #   get("/path", handler, middleware = @[mw1])
          handlerIdent = stmt[2]
          if stmt[3].kind == nnkExprEqExpr and stmt[3][0].eqIdent("middleware"):
            middlewaresNode = castMiddlewares(stmt[3][1])
          else:
            middlewaresNode = castMiddlewares(stmt[3])
        else:
          error(
            "Invalid route syntax. Use " &
            methodName & "(\"path\", handler) or " &
            methodName & "(\"path\", handler, middleware = @[mw])",
            stmt
          )

        # For inline handlers, use directly; for typed handlers, wrap with pattern
        let handlerValue = if isInline:
          handlerIdent
        else:
          newCall(ident"generateHandlerWrapper", handlerIdent, newStrLitNode(pattern.strVal))

        let entry = newNimNode(nnkObjConstr).add(
          ident"RouteEntry",
          newNimNode(nnkExprColonExpr).add(ident"httpMethod", methodIdent(methodName)),
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
