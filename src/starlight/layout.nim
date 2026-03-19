## Type-safe HTML layouts with zero overhead.
##
## Usage:
##   layout Page(title: string, content: string):
##     Html:
##       Head:
##         Title: title
##       Body:
##         raw content
##
##   Page(title="Hello", content="<h1>World</h1>")
##
## Buffered mode — all nested writes go to one shared buffer:
##   layout SiteHeader() {.buf.}:
##     Header:
##       H1: "My Site"
##
##   layout Shell(title: string, content: lazyLayout) {.buf.}:
##     Html:
##       Body:
##         content
##
##   layout Page(title: string) {.buf.}:
##     Shell(title=title, lazy content=SiteHeader())

import std/[macros, sets]
import html
import private/naming

export naming

proc collectLazyParams(signature: NimNode): seq[string] =
  ## Collect parameter names declared as `name: lazyLayout`.
  for i in 1..<signature.len:
    let param = signature[i]
    if param.kind == nnkExprColonExpr and
       param[1].kind == nnkIdent and param[1].strVal == "lazyLayout":
      result.add param[0].strVal

proc extractParams(
  signature: NimNode,
  lazyNames: seq[string] = default(seq[string]),
): tuple[procParams, tmplParams, callArgs: seq[NimNode]] =
  ## Extract parameter lists from layout signature.
  ## Parameters with `lazyLayout` type are excluded — handled separately.
  var procParams: seq[NimNode] = @[]
  var tmplParams: seq[NimNode] = @[]
  var callArgs: seq[NimNode] = @[]

  for i in 1..<signature.len:
    let param = signature[i]
    case param.kind
    of nnkExprColonExpr:
      if param[0].strVal in lazyNames:
        continue  # lazy params handled separately
      procParams.add newIdentDefs(param[0], param[1])
      tmplParams.add newIdentDefs(param[0], param[1])
      callArgs.add param[0]
    of nnkExprEqExpr:
      procParams.add newIdentDefs(param[0], newEmptyNode(), param[1])
      tmplParams.add newIdentDefs(param[0], newEmptyNode(), param[1])
      callArgs.add param[0]
    else:
      procParams.add newIdentDefs(param, ident"string")
      tmplParams.add newIdentDefs(param, ident"string")
      callArgs.add param

  result = (procParams, tmplParams, callArgs)

proc buildCapExpr(stmts: NimNode, hintKb: int): NimNode =
  ## Build compile-time expression for buffer capacity.
  let (staticLen, dynamicCount) = countBufAdds(stmts)

  var capExpr: NimNode = newIntLitNode(staticLen + dynamicCount * 64 + 256)

  if hintKb > 0:
    capExpr = newCall(ident"max", capExpr, newIntLitNode(hintKb * 1024))

  result = capExpr

proc generateBuffered(
  name: NimNode,
  body: NimNode,
  procParams, tmplParams, callArgs: seq[NimNode],
  lazyNames: seq[string],
  hintKb: int,
): NimNode =
  ## Generate buffered layout code (with {.buf.} pragma).
  let implName = layoutImplName(name.strVal)
  let staticCapName = ident(name.strVal & "_staticCap")
  let bufIdent = ident"buf"
  let lazySet = lazyNames.toHashSet
  let htmlStmts = generateHtmlBlockBuffered(body, bufIdent, lazySet)
  let capExpr = buildCapExpr(htmlStmts, hintKb)

  result = newStmtList()

  # const Name_staticCap* = <capExpr>
  result.add newNimNode(nnkConstSection).add(
    newNimNode(nnkConstDef).add(
      postfix(staticCapName, "*"),
      newEmptyNode(),
      capExpr
    )
  )

  # Nimcall proc type for lazy params (no closure env, zero heap allocation)
  let lazyProcType = newNimNode(nnkProcTy).add(
    newNimNode(nnkFormalParams).add(
      newEmptyNode(),
      newIdentDefs(ident"buf", newNimNode(nnkVarTy).add(ident"string"))
    ),
    newNimNode(nnkPragma).add(
      ident"nimcall",
      ident"gcsafe",
      newNimNode(nnkExprColonExpr).add(
        ident"raises",
        newNimNode(nnkBracket).add(ident"CatchableError")
      )
    )
  )

  # proc __layout__Name*(buf: var string, params...,
  #                      __lazy__content: proc(...), ...) {.inline.} =
  var implParams: seq[NimNode] = @[]
  implParams.add newEmptyNode()  # void return
  implParams.add newIdentDefs(bufIdent, newNimNode(nnkVarTy).add(ident"string"))
  for p in procParams:
    implParams.add p
  for lazyName in lazyNames:
    implParams.add newIdentDefs(lazyParamName(lazyName), lazyProcType)

  let implProc = newProc(
    name = postfix(implName, "*"),
    params = implParams,
    body = htmlStmts,
    procType = nnkProcDef,
  )
  implProc.addPragma(ident"inline")
  result.add implProc

  # No-op closure for lazy params: proc(buf: var string) = discard
  let noopLazy = newNimNode(nnkLambda).add(
    newEmptyNode(), newEmptyNode(), newEmptyNode(),
    newNimNode(nnkFormalParams).add(
      newEmptyNode(),
      newIdentDefs(ident"buf", newNimNode(nnkVarTy).add(ident"string"))
    ),
    newNimNode(nnkPragma).add(ident"nimcall"), newEmptyNode(),
    newStmtList(newNimNode(nnkDiscardStmt).add(newEmptyNode()))
  )

  # Wrapper template with context detection
  var wrapperParams: seq[NimNode] = @[]
  wrapperParams.add ident"untyped"  # return type
  for p in tmplParams:
    wrapperParams.add p

  # Build _impl call args (lazy params get no-op closures in wrapper)
  var fwdArgs: seq[NimNode] = @[]
  fwdArgs.add bufIdent
  for arg in callArgs:
    fwdArgs.add arg
  for lazyName in lazyNames:
    fwdArgs.add noopLazy

  var fwdCallBuf = newCall(implName)
  for arg in fwdArgs:
    fwdCallBuf.add arg

  var fwdCallStandalone = newCall(implName)
  for arg in fwdArgs:
    fwdCallStandalone.add arg

  # when declared(buf): __layout__Name(ctx, buf, ...); ""
  let bufBranch = newStmtList(fwdCallBuf, newStrLitNode(""))

  # else: block: var buf = ...; __layout__Name(ctx, buf, ...); buf
  let standaloneBranch = newBlockStmt(newEmptyNode(), newStmtList(
    newVarStmt(bufIdent, newCall(ident"newStringOfCap", staticCapName)),
    fwdCallStandalone,
    bufIdent
  ))

  let whenStmt = newNimNode(nnkWhenStmt).add(
    newNimNode(nnkElifBranch).add(
      newCall(ident"declared", bufIdent),
      bufBranch
    ),
    newNimNode(nnkElse).add(standaloneBranch)
  )

  let wrapper = newProc(
    name = postfix(name, "*"),
    params = wrapperParams,
    body = newStmtList(whenStmt),
    procType = nnkTemplateDef,
  )
  result.add wrapper

macro layout*(signature: untyped, body: untyped): untyped =
  ## Generates a proc with the user's name and parameters.
  ##
  ## With {.buf.} pragma, generates a buffered layout that writes
  ## directly to a shared buffer instead of returning a string.

  # Check for {.buf.} pragma
  var actualSignature = signature
  var isBuffered = false
  var hintKb = 0

  if signature.kind == nnkPragmaExpr:
    actualSignature = signature[0]
    for pragma in signature[1]:
      if pragma.kind == nnkIdent and pragma.strVal == "buf":
        isBuffered = true
      elif pragma.kind == nnkExprColonExpr and
           pragma[0].kind == nnkIdent and pragma[0].strVal == "buf":
        isBuffered = true
        if pragma[1].kind in {nnkIntLit..nnkUInt64Lit}:
          hintKb = pragma[1].intVal.int

  let name = actualSignature[0]
  let implName = layoutImplName(name.strVal)

  if isBuffered:
    let lazyNames = collectLazyParams(actualSignature)
    let (procParams, tmplParams, callArgs) = extractParams(actualSignature, lazyNames)
    return generateBuffered(name, body, procParams, tmplParams, callArgs, lazyNames, hintKb)

  # --- Regular layout ---

  let (procParams, _, _) = extractParams(actualSignature)

  # Build param list: just user params
  var fullProcParams: seq[NimNode] = @[]
  fullProcParams.add ident"string"  # return type
  for p in procParams:
    fullProcParams.add p

  # proc Name*(params...): string {.inline.} = generateHtmlBlock(body)
  let resultProc = newProc(
    name = postfix(name, "*"),
    params = fullProcParams,
    body = newStmtList(generateHtmlBlock(body)),
    procType = nnkProcDef,
  )
  resultProc.addPragma(ident"inline")

  result = newStmtList(resultProc)
