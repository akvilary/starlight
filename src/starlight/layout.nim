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
##   layout Header() {.toBuffer.}:
##     header:
##       h1: "My Site"
##
##   layout Wrapper(title: string) {.toBuffer.}:
##     html:
##       body:
##         container       # slot for caller's content
##
##   layout Page(title: string) {.toBuffer.}:
##     containered Wrapper(title=title):
##       Header()          # {.toBuffer.} → writes to shared buf
##       main:
##         h1: "Welcome"

import std/macros
import html
import private/naming

export naming

proc hasContainerSlot(node: NimNode): bool =
  ## Recursively checks if the body contains a bare `container` ident.
  case node.kind
  of nnkIdent:
    return node.strVal == "container"
  else:
    for child in node:
      if hasContainerSlot(child):
        return true
    return false

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
  ## Generate buffered layout code (with {.toBuffer.} pragma).
  let implName = layoutImplName(name.strVal)
  let staticCapName = ident(name.strVal & "_staticCap")
  let hasSlot = hasContainerSlot(body)
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

  if hasSlot:
    # Template-based _impl for slot injection:
    # template Name_impl*(ctx, buf: untyped, params..., containerBody: untyped) =
    #   buf.add "..."
    #   containerBody
    #   buf.add "..."
    var implParams: seq[NimNode] = @[]
    implParams.add newEmptyNode()  # void return
    implParams.add newIdentDefs(ident"ctx", newEmptyNode())  # untyped ctx
    implParams.add newIdentDefs(bufIdent, newEmptyNode())  # untyped buf
    for p in procParams:
      implParams.add p
    implParams.add newIdentDefs(ident"containerBody", newEmptyNode())  # untyped

    let implTmpl = newProc(
      name = postfix(implName, "*"),
      params = implParams,
      body = htmlStmts,
      procType = nnkTemplateDef,
    )
    result.add implTmpl
  else:
    # Proc-based _impl for no-slot buffered layouts:
    # proc Name_impl*(ctx: Context, buf: var string, params...) {.inline.} =
    #   buf.add "..."
    var implParams: seq[NimNode] = @[]
    implParams.add newEmptyNode()  # void return
    implParams.add newIdentDefs(ident"ctx", ident"Context")
    implParams.add newIdentDefs(bufIdent, newNimNode(nnkVarTy).add(ident"string"))
    for p in procParams:
      implParams.add p

    let implProc = newProc(
      name = postfix(implName, "*"),
      params = implParams,
      body = htmlStmts,
      procType = nnkProcDef,
    )
    implProc.addPragma(ident"inline")
    result.add implProc

  # Wrapper template with context detection:
  # template Name*(...): untyped =
  #   when declared(buf):
  #     Name_impl(ctx, buf, ...)
  #     ""
  #   else:
  #     block:
  #       var buf = newStringOfCap(Name_staticCap)
  #       Name_impl(ctx, buf, ...)
  #       buf
  var wrapperParams: seq[NimNode] = @[]
  wrapperParams.add ident"untyped"  # return type
  for p in tmplParams:
    wrapperParams.add p
  if hasSlot:
    wrapperParams.add newIdentDefs(ident"containerBody", newEmptyNode())

  # Build _impl call args
  var fwdArgs: seq[NimNode] = @[]
  fwdArgs.add ident"ctx"
  fwdArgs.add bufIdent
  for arg in callArgs:
    fwdArgs.add arg
  if hasSlot:
    fwdArgs.add ident"containerBody"

  var fwdCallBuf = newCall(implName)
  for arg in fwdArgs:
    fwdCallBuf.add arg

  var fwdCallStandalone = newCall(implName)
  for arg in fwdArgs:
    fwdCallStandalone.add arg

  # when declared(buf): Name_impl(ctx, buf, ...); ""
  let bufBranch = newStmtList(fwdCallBuf, newStrLitNode(""))

  # else: block: var buf = ...; Name_impl(ctx, buf, ...); buf
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
  ## With {.toBuffer.} pragma, generates a buffered layout that writes
  ## directly to a shared buffer instead of returning a string.

  # Check for {.toBuffer.} pragma
  var actualSignature = signature
  var isBuffered = false
  var hintKb = 0

  if signature.kind == nnkPragmaExpr:
    actualSignature = signature[0]
    for pragma in signature[1]:
      if pragma.kind == nnkIdent and pragma.strVal == "toBuffer":
        isBuffered = true
      elif pragma.kind == nnkExprColonExpr and
           pragma[0].kind == nnkIdent and pragma[0].strVal == "toBuffer":
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
