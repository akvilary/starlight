## HTML DSL macro with compile-time static/dynamic splitting.
##
## Usage:
##   let page = Html:
##     H1: "Hello"
##     P: userName
##     Div(class="container"):
##       if loggedIn:
##         A(href="/logout"): "Logout"

import std/[macros, macrocache, sets, tables]
import private/tags
import private/escape
import private/naming

export escape, tags

proc resolveTagName(node: NimNode): string =
  ## Extracts tag name from ident or backtick-quoted ident.
  case node.kind
  of nnkIdent:
    result = node.strVal
  of nnkAccQuoted:
    if node.len > 0:
      result = node[0].strVal
  else:
    result = ""

proc isTag(name: string): bool =
  name in htmlTags

proc isVoid(name: string): bool =
  name in voidTags

proc flushLit(stmts: NimNode, buf: NimNode, lit: var string) =
  if lit.len > 0:
    stmts.add newCall(newDotExpr(buf, ident"add"), newStrLitNode(lit))
    lit = ""

proc addToBuf(
  stmts: NimNode,
  buf: NimNode,
  expr: NimNode,
  stringify: bool = true,
) =
  ## Add expression to the buffer. Uses let-binding for calls to prevent
  ## double evaluation. When stringify=true, wraps with `$`.
  proc wrapExpr(e: NimNode): NimNode =
    if stringify: newCall(ident"$", e) else: e
  if expr.kind in {nnkCall, nnkCommand}:
    let tmp = genSym(nskLet, "tmp")
    stmts.add newLetStmt(tmp, expr)
    stmts.add newCall(newDotExpr(buf, ident"add"), wrapExpr(tmp))
  else:
    stmts.add newCall(newDotExpr(buf, ident"add"), wrapExpr(expr))

proc makeLazyLambda(expr: NimNode): NimNode =
  ## Wrap an expression in a nimcall proc: proc(buf: var string) {.nimcall.} =
  ##   let tmp = expr; buf.add($tmp)
  let lambdaBuf = ident"buf"
  let tmp = genSym(nskLet, "lazyTmp")
  let lambdaBody = newStmtList(
    newLetStmt(tmp, expr),
    newCall(newDotExpr(lambdaBuf, ident"add"),
            newCall(ident"$", tmp))
  )
  result = newNimNode(nnkLambda).add(
    newEmptyNode(),  # name
    newEmptyNode(),  # patterns
    newEmptyNode(),  # generic params
    newNimNode(nnkFormalParams).add(
      newEmptyNode(),  # void return
      newIdentDefs(lambdaBuf, newNimNode(nnkVarTy).add(ident"string"))
    ),
    newNimNode(nnkPragma).add(ident"nimcall"),  # nimcall — no closure env needed
    newEmptyNode(),  # reserved
    lambdaBody
  )

proc hasLazyArgs(node: NimNode): bool =
  ## Check if a call node has any `lazy name=expr` arguments.
  for i in 1..<node.len:
    let arg = node[i]
    if arg.kind == nnkExprEqExpr and arg[0].kind == nnkCommand and
       arg[0].len >= 2 and arg[0][0].kind == nnkIdent and arg[0][0].strVal == "lazy":
      return true
  return false

proc processContent(
  node: NimNode,
  stmts: NimNode,
  buf: NimNode,
  lit: var string,
  lazyParams: Table[string, LazyInfo],
)
proc processNode(
  node: NimNode,
  stmts: NimNode,
  buf: NimNode,
  lit: var string,
  lazyParams: Table[string, LazyInfo],
)

proc processBodyBlock(
  node: NimNode,
  buf: NimNode,
  lit: var string,
  lazyParams: Table[string, LazyInfo],
): NimNode =
  ## Process a control flow body into a new StmtList, flushing literals.
  var body = newStmtList()
  processNode(node, body, buf, lit, lazyParams)
  flushLit(body, buf, lit)
  body

proc rebuildBranch(
  kind: NimNodeKind,
  branch: NimNode,
  buf: NimNode,
  lit: var string,
  lazyParams: Table[string, LazyInfo],
): NimNode =
  ## Rebuild an AST branch node: copy leading children, replace last with
  ## processBodyBlock. Used for OfBranch, ExceptBranch, ForStmt.
  let body = processBodyBlock(branch[^1], buf, lit, lazyParams)
  result = newNimNode(kind)
  for j in 0..<branch.len - 1:
    result.add branch[j]
  result.add body

proc processContent(
  node: NimNode,
  stmts: NimNode,
  buf: NimNode,
  lit: var string,
  lazyParams: Table[string, LazyInfo],
) =
  ## Process a content expression (not a tag).
  case node.kind
  of nnkStrLit, nnkTripleStrLit, nnkRStrLit:
    lit.add escapeHtml(node.strVal)
  of nnkIntLit..nnkUInt64Lit:
    lit.add $node.intVal
  of nnkFloatLit..nnkFloat64Lit:
    lit.add $node.floatVal
  else:
    flushLit(stmts, buf, lit)
    addToBuf(stmts, buf, node)

proc processTag(
  node: NimNode,
  tagName: string,
  stmts: NimNode,
  buf: NimNode,
  lit: var string,
  lazyParams: Table[string, LazyInfo],
) =
  ## Process an HTML tag node.
  let htmlTag = tagToHtml(tagName)
  lit.add "<" & htmlTag

  # Collect attributes and body
  for i in 1..<node.len:
    let child = node[i]
    if child.kind == nnkExprEqExpr:
      let attrName = $child[0]
      let attrVal = child[1]
      lit.add " " & attrName & "=\""
      if attrVal.kind in {nnkStrLit, nnkTripleStrLit, nnkRStrLit}:
        lit.add escapeHtml(attrVal.strVal)
        lit.add "\""
      else:
        flushLit(stmts, buf, lit)
        addToBuf(stmts, buf, attrVal)
        lit = "\""

  if isVoid(tagName):
    lit.add "/>"
  else:
    lit.add ">"
    # Process children (StmtList and direct content)
    for i in 1..<node.len:
      let child = node[i]
      if child.kind == nnkExprEqExpr:
        continue
      elif child.kind == nnkStmtList:
        processNode(child, stmts, buf, lit, lazyParams)
      else:
        processContent(child, stmts, buf, lit, lazyParams)
    lit.add "</" & htmlTag & ">"

proc extractCallTarget(expr: NimNode): string =
  ## Extract layout name from a call expression (e.g., SiteHeader() → "SiteHeader").
  if expr.kind in {nnkCall, nnkCommand} and expr.len > 0:
    if expr[0].kind == nnkIdent:
      return expr[0].strVal
    elif expr[0].kind == nnkAccQuoted and expr[0].len > 0:
      return expr[0][0].strVal

proc checkLazyType(
  targetLayout, paramName, got: string,
  errorNode: NimNode,
) =
  ## Check that `got` matches the expected type for this lazy param.
  let key = targetLayout & "." & paramName
  if lazyTypeRegistry.hasKey(key):
    let expected = lazyTypeRegistry[key].strVal
    if got != expected:
      error("lazy '" & paramName & "' of " & targetLayout &
            " expects " & expected & ", got " & got, errorNode)

proc transformLazyCall(
  node: NimNode,
  stmts: NimNode,
  buf: NimNode,
  lit: var string,
  lazyParams: Table[string, LazyInfo],
) =
  ## Transform a call with lazy args: call __layout__Name(buf, ...) directly,
  ## wrapping lazy exprs in closures.
  flushLit(stmts, buf, lit)
  let targetLayout = node[0].strVal
  let implName = layoutImplName(targetLayout)
  var newCallNode = newCall(implName, buf)
  for i in 1..<node.len:
    let arg = node[i]
    if arg.kind == nnkExprEqExpr and arg[0].kind == nnkCommand and
       arg[0].len >= 2 and arg[0][0].kind == nnkIdent and arg[0][0].strVal == "lazy":
      let paramName = arg[0][1].strVal  # actual param name
      let expr = arg[1]                 # expression to defer
      if expr.kind == nnkIdent and expr.strVal in lazyParams:
        # Forward lazy param — check source type vs target type
        let sourceType = lazyParams[expr.strVal].typeName
        if sourceType.len > 0:
          checkLazyType(targetLayout, paramName, sourceType, expr)
        let fwdName = if lazyParams[expr.strVal].kind == lkRaw:
          ident(expr.strVal) else: lazyParamName(expr.strVal)
        newCallNode.add newNimNode(nnkExprEqExpr).add(
          lazyParamName(paramName), fwdName)
      elif expr.kind == nnkBracket:
        # Array of lazy exprs → stack array of closures (zero heap alloc)
        var arrExpr = newNimNode(nnkBracket)
        for item in expr:
          let got = extractCallTarget(item)
          if got.len > 0:
            checkLazyType(targetLayout, paramName, got, item)
          arrExpr.add makeLazyLambda(item)
        newCallNode.add newNimNode(nnkExprEqExpr).add(
          lazyParamName(paramName), arrExpr)
      else:
        # Single lazy expr — type check + wrap in closure
        let got = extractCallTarget(expr)
        if got.len > 0:
          checkLazyType(targetLayout, paramName, got, expr)
        newCallNode.add newNimNode(nnkExprEqExpr).add(
          lazyParamName(paramName), makeLazyLambda(expr))
    else:
      newCallNode.add arg
  stmts.add newCallNode

proc processNode(
  node: NimNode,
  stmts: NimNode,
  buf: NimNode,
  lit: var string,
  lazyParams: Table[string, LazyInfo],
) =
  case node.kind
  of nnkStmtList:
    for child in node:
      processNode(child, stmts, buf, lit, lazyParams)

  of nnkCall, nnkCommand:
    let firstName = resolveTagName(node[0])
    if isTag(firstName):
      processTag(node, firstName, stmts, buf, lit, lazyParams)
    elif node[0].kind == nnkIdent and node[0].strVal == "raw":
      # raw — insert without escaping
      flushLit(stmts, buf, lit)
      let content = if node.len > 1 and node[1].kind == nnkStmtList: node[1][0]
                    elif node.len > 1: node[1]
                    else: newStrLitNode("")
      addToBuf(stmts, buf, content, stringify = false)
    elif hasLazyArgs(node):
      # Call with lazy args — wrap lazy exprs in closures
      transformLazyCall(node, stmts, buf, lit, lazyParams)
    else:
      # Not a tag — treat as expression
      processContent(node, stmts, buf, lit, lazyParams)

  of nnkPrefix:
    flushLit(stmts, buf, lit)
    stmts.add node

  of nnkIdent:
    let name = node.strVal
    if name in lazyParams:
      flushLit(stmts, buf, lit)
      case lazyParams[name].kind
      of lkSingle:
        stmts.add newCall(lazyParamName(name), buf)
      of lkSeq:
        let itemSym = genSym(nskForVar, "lazyItem")
        stmts.add newNimNode(nnkForStmt).add(
          itemSym, lazyParamName(name),
          newStmtList(newCall(itemSym, buf)))
      of lkRaw:
        stmts.add newCall(ident(name), buf)
    elif isTag(name) and isVoid(name):
      # Only void tags can be bare identifiers (e.g., Br, Hr)
      lit.add "<" & tagToHtml(name) & "/>"
    else:
      processContent(node, stmts, buf, lit, lazyParams)

  of nnkAccQuoted:
    let name = if node.len > 0: node[0].strVal else: ""
    if isTag(name) and isVoid(name):
      lit.add "<" & tagToHtml(name) & "/>"
    else:
      processContent(node, stmts, buf, lit, lazyParams)

  of nnkIfStmt, nnkIfExpr:
    flushLit(stmts, buf, lit)
    var ifNode = newNimNode(nnkIfStmt)
    for branch in node:
      case branch.kind
      of nnkElifBranch, nnkElifExpr:
        let body = processBodyBlock(branch[1], buf, lit, lazyParams)
        ifNode.add newNimNode(nnkElifBranch).add(branch[0], body)
      of nnkElse, nnkElseExpr:
        let body = processBodyBlock(branch[0], buf, lit, lazyParams)
        ifNode.add newNimNode(nnkElse).add(body)
      else: discard
    stmts.add ifNode

  of nnkForStmt:
    flushLit(stmts, buf, lit)
    let iterExpr = node[^2]
    if iterExpr.kind == nnkIdent and iterExpr.strVal in lazyParams and
       lazyParams[iterExpr.strVal].kind == lkSeq:
      let loopVar = node[0]
      var innerParams = lazyParams
      innerParams[loopVar.strVal] = (lkRaw, lazyParams[iterExpr.strVal].typeName)
      let body = processBodyBlock(node[^1], buf, lit, innerParams)
      stmts.add newNimNode(nnkForStmt).add(
        loopVar, lazyParamName(iterExpr.strVal), body)
    else:
      stmts.add rebuildBranch(nnkForStmt, node, buf, lit, lazyParams)

  of nnkWhileStmt:
    flushLit(stmts, buf, lit)
    let body = processBodyBlock(node[1], buf, lit, lazyParams)
    stmts.add newNimNode(nnkWhileStmt).add(node[0], body)

  of nnkCaseStmt:
    flushLit(stmts, buf, lit)
    var caseNode = newNimNode(nnkCaseStmt)
    caseNode.add node[0]
    for i in 1..<node.len:
      let branch = node[i]
      case branch.kind
      of nnkOfBranch:
        caseNode.add rebuildBranch(nnkOfBranch, branch, buf, lit, lazyParams)
      of nnkElse:
        let body = processBodyBlock(branch[0], buf, lit, lazyParams)
        caseNode.add newNimNode(nnkElse).add(body)
      else: discard
    stmts.add caseNode

  of nnkTryStmt:
    flushLit(stmts, buf, lit)
    var tryNode = newNimNode(nnkTryStmt)
    tryNode.add processBodyBlock(node[0], buf, lit, lazyParams)
    for i in 1..<node.len:
      let branch = node[i]
      case branch.kind
      of nnkExceptBranch:
        tryNode.add rebuildBranch(nnkExceptBranch, branch, buf, lit, lazyParams)
      of nnkFinally:
        let body = processBodyBlock(branch[0], buf, lit, lazyParams)
        tryNode.add newNimNode(nnkFinally).add(body)
      else: discard
    stmts.add tryNode

  of nnkVarSection, nnkLetSection, nnkConstSection, nnkAsgn, nnkDiscardStmt:
    flushLit(stmts, buf, lit)
    stmts.add node

  of nnkStrLit, nnkTripleStrLit, nnkRStrLit:
    lit.add escapeHtml(node.strVal)

  of nnkIntLit..nnkUInt64Lit:
    lit.add $node.intVal

  of nnkFloatLit..nnkFloat64Lit:
    lit.add $node.floatVal

  else:
    processContent(node, stmts, buf, lit, lazyParams)

proc countBufAdds*(
  stmts: NimNode,
): tuple[staticLen: int, dynamicExprs: int] =
  ## Count static string length and dynamic expression count in a single pass.
  for stmt in stmts:
    if stmt.kind == nnkCall and stmt.len > 1:
      if stmt[0].kind == nnkDotExpr and stmt[0][1].eqIdent("add"):
        if stmt[^1].kind == nnkStrLit:
          result.staticLen += stmt[^1].strVal.len
        else:
          inc result.dynamicExprs
    for child in stmt:
      var nested: NimNode
      if child.kind == nnkStmtList:
        nested = child
      elif child.kind in {nnkElifBranch, nnkOfBranch} and
           child[^1].kind == nnkStmtList:
        nested = child[^1]
      elif child.kind == nnkElse and child[0].kind == nnkStmtList:
        nested = child[0]
      else:
        continue
      let sub = countBufAdds(nested)
      result.staticLen += sub.staticLen
      result.dynamicExprs += sub.dynamicExprs

proc generateHtmlBlock*(body: NimNode): NimNode =
  ## Generate HTML rendering code from DSL body. Called by the layout macro.
  let buf = genSym(nskVar, "htmlBuf")
  var stmts = newStmtList()
  var lit = ""

  processNode(body, stmts, buf, lit, default(Table[string, LazyInfo]))
  flushLit(stmts, buf, lit)

  let cap = countBufAdds(stmts).staticLen + 256

  var resultStmts = newStmtList()
  resultStmts.add newVarStmt(buf, newCall(ident"newStringOfCap", newIntLitNode(cap)))
  for stmt in stmts:
    resultStmts.add stmt
  resultStmts.add buf

  result = newBlockStmt(newEmptyNode(), resultStmts)

proc generateHtmlBlockBuffered*(
  body: NimNode,
  buf: NimNode,
  lazyParams: Table[string, LazyInfo] = default(Table[string, LazyInfo]),
): NimNode =
  ## Generate HTML rendering code that writes to an existing buffer.
  ## Unlike generateHtmlBlock, does not create or return the buffer.
  var stmts = newStmtList()
  var lit = ""
  processNode(body, stmts, buf, lit, lazyParams)
  flushLit(stmts, buf, lit)
  result = stmts
