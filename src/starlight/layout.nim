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
##   layout Shell[T](title: string, content: lazyLayout[T]) {.buf.}:
##     Html:
##       Body:
##         content
##
##   layout Page(title: string) {.buf.}:
##     Shell(title=title, lazy content=SiteHeader())

import std/[macros, macrocache, tables]
import html
import private/naming

export naming

proc isLazyLayoutType(typeNode: NimNode): bool =
  ## Check if type node is `lazyLayout[X]`.
  typeNode.kind == nnkBracketExpr and
  typeNode[0].kind == nnkIdent and typeNode[0].strVal == "lazyLayout" and
  typeNode.len > 1

proc collectLazyParams(
  signature: NimNode,
  genericParams: seq[string] = default(seq[string]),
): seq[LazyParam] =
  ## Collect parameters declared as `name: lazyLayout[X]`
  ## or `name: openarray[lazyLayout[X]]`.
  ## If X is a generic param of the layout, no compile-time type check.
  for i in 1..<signature.len:
    let param = signature[i]
    if param.kind != nnkExprColonExpr:
      continue
    let typeNode = param[1]
    if isLazyLayoutType(typeNode):
      let typeName = typeNode[1].strVal
      result.add LazyParam(
        name: param[0].strVal,
        kind: lkSingle,
        typeName: if typeName in genericParams: "" else: typeName,
      )
    elif typeNode.kind == nnkBracketExpr and
         typeNode[0].kind == nnkIdent and typeNode[0].strVal.eqIdent("openarray") and
         typeNode.len > 1 and isLazyLayoutType(typeNode[1]):
      let typeName = typeNode[1][1].strVal
      result.add LazyParam(
        name: param[0].strVal,
        kind: lkSeq,
        typeName: if typeName in genericParams: "" else: typeName,
      )

proc extractParams(
  signature: NimNode,
  lazyParams: seq[LazyParam] = default(seq[LazyParam]),
): tuple[procParams, tmplParams, callArgs: seq[NimNode]] =
  ## Extract parameter lists from layout signature.
  ## Parameters with `lazyLayout` type are excluded — handled separately.
  ## procParams and tmplParams are structurally identical but must be
  ## separate NimNode instances (Nim AST requires distinct nodes per proc).
  var lazyNames: seq[string]
  for lp in lazyParams:
    lazyNames.add lp.name

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
  lazyParams: seq[LazyParam],
  hintKb: int,
  isExported: bool,
): NimNode =
  ## Generate buffered layout code (with {.buf.} pragma).
  let implName = layoutImplName(name.strVal)
  let staticCapName = ident(name.strVal & "_staticCap")
  let bufIdent = ident"buf"

  var lazyTable = initTable[string, LazyInfo]()
  for lp in lazyParams:
    lazyTable[lp.name] = (lp.kind, lp.typeName)
    if lp.typeName.len > 0:
      lazyTypeRegistry[name.strVal & "." & lp.name] = newLit(lp.typeName)
  let htmlStmts = generateHtmlBlockBuffered(body, bufIdent, lazyTable)
  let capExpr = buildCapExpr(htmlStmts, hintKb)

  result = newStmtList()

  # const Name_staticCap* = <capExpr>
  result.add newNimNode(nnkConstSection).add(
    newNimNode(nnkConstDef).add(
      maybeExport(staticCapName, isExported),
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

  # openArray[ProcType] for seq lazy params (zero heap allocation)
  let lazyOpenArrayType = newNimNode(nnkBracketExpr).add(
    ident"openArray", lazyProcType.copyNimTree)

  # proc __layout__Name*(buf: var string, params...,
  #                      __lazy__content: proc(...) | openArray[proc(...)],
  #                      ...) {.inline.} =
  var implParams: seq[NimNode] = @[]
  implParams.add newEmptyNode()  # void return
  implParams.add newIdentDefs(bufIdent, newNimNode(nnkVarTy).add(ident"string"))
  for p in procParams:
    implParams.add p
  for lp in lazyParams:
    case lp.kind
    of lkSingle:
      implParams.add newIdentDefs(
        lazyParamName(lp.name), lazyProcType.copyNimTree)
    of lkSeq:
      implParams.add newIdentDefs(
        lazyParamName(lp.name), lazyOpenArrayType.copyNimTree)
    of lkRaw:
      discard

  let implProc = newProc(
    name = maybeExport(implName, isExported),
    params = implParams,
    body = htmlStmts,
    procType = nnkProcDef,
  )
  implProc.addPragma(ident"inline")
  result.add implProc

  # No-op closure for single lazy params: proc(buf: var string) = discard
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

  # Build _impl call: __layout__Name(buf, args..., lazy defaults...)
  proc makeFwdCall(): NimNode =
    result = newCall(implName, bufIdent)
    for arg in callArgs:
      result.add arg
    for lp in lazyParams:
      case lp.kind
      of lkSingle:
        result.add noopLazy.copyNimTree
      of lkSeq:
        # Empty bracket [] — empty openArray, zero allocation
        result.add newNimNode(nnkBracket)
      of lkRaw:
        discard

  # when declared(buf): __layout__Name(ctx, buf, ...); ""
  let bufBranch = newStmtList(makeFwdCall(), newStrLitNode(""))

  # else: block: var buf = ...; __layout__Name(ctx, buf, ...); buf
  let standaloneBranch = newBlockStmt(newEmptyNode(), newStmtList(
    newVarStmt(bufIdent, newCall(ident"newStringOfCap", staticCapName)),
    makeFwdCall(),
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
    name = maybeExport(name, isExported),
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

  let (normalizedSig, isExported) = normalizeExportMarker(signature)

  # Check for {.buf.} pragma
  var actualSignature = normalizedSig
  var isBuffered = false
  var hintKb = 0

  if normalizedSig.kind == nnkPragmaExpr:
    actualSignature = normalizedSig[0]
    for pragma in normalizedSig[1]:
      if pragma.kind == nnkIdent and pragma.strVal == "buf":
        isBuffered = true
      elif pragma.kind == nnkExprColonExpr and
           pragma[0].kind == nnkIdent and pragma[0].strVal == "buf":
        isBuffered = true
        if pragma[1].kind in {nnkIntLit..nnkUInt64Lit}:
          hintKb = pragma[1].intVal.int

  let nameNode = actualSignature[0]
  var name: NimNode
  var genericParams: seq[string]

  if nameNode.kind == nnkBracketExpr:
    name = nameNode[0]
    for i in 1..<nameNode.len:
      genericParams.add nameNode[i].strVal
  else:
    name = nameNode

  if isBuffered:
    let lazyParams = collectLazyParams(actualSignature, genericParams)
    let (procParams, tmplParams, callArgs) = extractParams(actualSignature, lazyParams)
    return generateBuffered(
      name, body, procParams, tmplParams, callArgs, lazyParams, hintKb, isExported,
    )

  # --- Regular layout ---

  let (procParams, _, _) = extractParams(actualSignature)

  # Build param list: just user params
  var fullParams: seq[NimNode] = @[]
  fullParams.add ident"string"  # return type
  for p in procParams:
    fullParams.add p

  let resultProc = newProc(
    name = maybeExport(name, isExported),
    params = fullParams,
    body = newStmtList(generateHtmlBlock(body)),
    procType = nnkProcDef,
  )
  resultProc.addPragma(ident"inline")

  result = newStmtList(resultProc)
