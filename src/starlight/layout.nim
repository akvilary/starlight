## Type-safe HTML layouts with zero overhead.
##
## Usage:
##   layout Page(title: string, content: string):
##     html:
##       head:
##         title: title
##       body:
##         raw content
##
##   # In a handler (ctx is implicit):
##   Page(title="Hello", content="<h1>World</h1>")
##
## Buffered mode — all nested writes go to one shared buffer:
##   layout SiteHeader() {.buf.}:
##     Header:
##       H1: "My Site"
##
##   layout Shell(title: string) {.buf.}:
##     Html:
##       Body:
##         <-S1            # named slot
##
##   layout Page(title: string) {.buf.}:
##     inject Shell(title=title):
##       ->S1:
##         SiteHeader()
##         Main:
##           H1: "Welcome"

import std/macros
import html
import private/naming

export naming

proc collectSlotNames(node: NimNode, result: var seq[string]) =
  ## Recursively finds <-Sn slot markers and collects their names.
  case node.kind
  of nnkPrefix:
    if node[0].kind == nnkIdent and node[0].strVal == "<-":
      let name = node[1].strVal
      if name notin result:
        result.add name
  else:
    for child in node:
      collectSlotNames(child, result)

proc extractParams(signature: NimNode): tuple[
  procParams, tmplParams, callArgs: seq[NimNode]] =
  ## Extract parameter lists from layout signature.
  var procParams: seq[NimNode] = @[]
  var tmplParams: seq[NimNode] = @[]
  var callArgs: seq[NimNode] = @[]

  for i in 1..<signature.len:
    let param = signature[i]
    case param.kind
    of nnkExprColonExpr:
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

proc buildCapExpr(stmts, body: NimNode, hintKb: int): NimNode =
  ## Build compile-time expression for buffer capacity.
  ## Formula: max(staticLen + dynamicCount*64 + sum(nestedCaps) + 256, hintKb*1024)
  let staticLen = countStaticLen(stmts)
  let dynamicCount = countDynamicExprs(stmts)
  let nestedCaps = collectNestedCaps(body)

  # Start with: staticLen + dynamicCount * 64 + 256
  var capExpr: NimNode = newIntLitNode(staticLen + dynamicCount * 64 + 256)

  # Add nested layout caps: + Name_staticCap + ...
  for cap in nestedCaps:
    capExpr = newCall(ident"+", capExpr, cap)

  # Apply hint: max(computed, hintKb * 1024)
  if hintKb > 0:
    capExpr = newCall(ident"max", capExpr, newIntLitNode(hintKb * 1024))

  result = capExpr

proc generateBuffered(name: NimNode, body: NimNode,
                      procParams, tmplParams, callArgs: seq[NimNode],
                      hintKb: int): NimNode =
  ## Generate buffered layout code (with {.buf.} pragma).
  let implName = layoutImplName(name.strVal)
  let staticCapName = ident(name.strVal & "_staticCap")
  var slotNames: seq[string] = @[]
  collectSlotNames(body, slotNames)
  let hasSlots = slotNames.len > 0
  let bufIdent = ident"buf"
  let htmlStmts = generateHtmlBlockBuffered(body, bufIdent)
  let capExpr = buildCapExpr(htmlStmts, body, hintKb)

  result = newStmtList()

  # const Name_staticCap* = <capExpr>
  result.add newNimNode(nnkConstSection).add(
    newNimNode(nnkConstDef).add(
      postfix(staticCapName, "*"),
      newEmptyNode(),
      capExpr
    )
  )

  # Always proc-based _impl:
  # proc __layout__Name*(ctx: Context, buf: var string, params...,
  #                      S1Body: proc(ctx: Context, buf: var string), ...) {.inline.} =
  let slotProcType = newNimNode(nnkProcTy).add(
    newNimNode(nnkFormalParams).add(
      newEmptyNode(),
      newIdentDefs(ident"ctx", ident"Context"),
      newIdentDefs(ident"buf", newNimNode(nnkVarTy).add(ident"string"))
    ),
    newNimNode(nnkPragma).add(
      ident"gcsafe",
      newNimNode(nnkExprColonExpr).add(
        ident"raises",
        newNimNode(nnkBracket).add(ident"CatchableError")
      )
    )
  )

  var implParams: seq[NimNode] = @[]
  implParams.add newEmptyNode()  # void return
  implParams.add newIdentDefs(ident"ctx", ident"Context")
  implParams.add newIdentDefs(bufIdent, newNimNode(nnkVarTy).add(ident"string"))
  for p in procParams:
    implParams.add p
  for slot in slotNames:
    implParams.add newIdentDefs(injectSlotName(slot), slotProcType)

  let implProc = newProc(
    name = postfix(implName, "*"),
    params = implParams,
    body = htmlStmts,
    procType = nnkProcDef,
  )
  implProc.addPragma(ident"inline")
  result.add implProc

  # No-op closure for empty slots: proc(ctx: Context, buf: var string) = discard
  let noopSlot = newNimNode(nnkLambda).add(
    newEmptyNode(), newEmptyNode(), newEmptyNode(),
    newNimNode(nnkFormalParams).add(
      newEmptyNode(),
      newIdentDefs(ident"ctx", ident"Context"),
      newIdentDefs(ident"buf", newNimNode(nnkVarTy).add(ident"string"))
    ),
    newEmptyNode(), newEmptyNode(),
    newStmtList(newNimNode(nnkDiscardStmt).add(newEmptyNode()))
  )

  # Wrapper template with context detection:
  var wrapperParams: seq[NimNode] = @[]
  wrapperParams.add ident"untyped"  # return type
  for p in tmplParams:
    wrapperParams.add p

  # Build _impl call args (slots get no-op closures in the wrapper)
  var fwdArgs: seq[NimNode] = @[]
  fwdArgs.add ident"ctx"
  fwdArgs.add bufIdent
  for arg in callArgs:
    fwdArgs.add arg
  for slot in slotNames:
    fwdArgs.add noopSlot

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
  ## Generates an inline proc (with ctx: Context) and a template wrapper
  ## (without ctx) for implicit context passing.
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
  let (procParams, tmplParams, callArgs) = extractParams(actualSignature)

  if isBuffered:
    return generateBuffered(name, body, procParams, tmplParams, callArgs, hintKb)

  # --- Regular layout (unchanged) ---

  # Build param list for proc: ctx: Context, then user params
  var fullProcParams: seq[NimNode] = @[]
  fullProcParams.add ident"string"  # return type
  fullProcParams.add newIdentDefs(ident"ctx", ident"Context")
  for p in procParams:
    fullProcParams.add p

  # Build param list for template: just user params (no ctx)
  var fullTmplParams: seq[NimNode] = @[]
  fullTmplParams.add ident"string"  # return type
  for p in tmplParams:
    fullTmplParams.add p

  # Collect call args for template -> proc forwarding
  var fullCallArgs: seq[NimNode] = @[]
  fullCallArgs.add ident"ctx"
  for arg in callArgs:
    fullCallArgs.add arg

  # proc Name_impl*(ctx: Context, ...): string {.inline.} = generateHtmlBlock(body)
  let implProc = newProc(
    name = postfix(implName, "*"),
    params = fullProcParams,
    body = newStmtList(generateHtmlBlock(body)),
    procType = nnkProcDef,
  )
  implProc.addPragma(ident"inline")

  # template Name*(...): string = Name_impl(ctx, ...)
  let forwardCall = newCall(implName, fullCallArgs)
  let tmpl = newProc(
    name = postfix(name, "*"),
    params = fullTmplParams,
    body = newStmtList(forwardCall),
    procType = nnkTemplateDef,
  )

  result = newStmtList(implProc, tmpl)
