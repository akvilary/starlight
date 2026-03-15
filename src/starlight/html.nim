## HTML DSL macro with compile-time static/dynamic splitting.
##
## Usage:
##   let page = html:
##     h1: "Hello"
##     p: userName
##     tdiv(class="container"):
##       if loggedIn:
##         a(href="/logout"): "Logout"

import std/[macros, sets]
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

proc addDynamic(stmts: NimNode, buf: NimNode, expr: NimNode) =
  ## Add a dynamic (runtime) expression to the buffer with HTML escaping.
  ## Uses let-binding for calls to prevent double evaluation.
  if expr.kind in {nnkCall, nnkCommand}:
    let tmp = genSym(nskLet, "tmp")
    stmts.add newLetStmt(tmp, expr)
    stmts.add newCall(newDotExpr(buf, ident"add"),
                      newCall(ident"escapeHtml", newCall(ident"$", tmp)))
  else:
    stmts.add newCall(newDotExpr(buf, ident"add"),
                      newCall(ident"escapeHtml", newCall(ident"$", expr)))

proc processContent(node: NimNode, stmts: NimNode, buf: NimNode, lit: var string)
proc processNode(node: NimNode, stmts: NimNode, buf: NimNode, lit: var string)

proc processContent(node: NimNode, stmts: NimNode, buf: NimNode, lit: var string) =
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
    addDynamic(stmts, buf, node)

proc processTag(node: NimNode, tagName: string, stmts: NimNode,
                buf: NimNode, lit: var string) =
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
        if attrVal.kind in {nnkCall, nnkCommand}:
          let tmp = genSym(nskLet, "attr")
          stmts.add newLetStmt(tmp, attrVal)
          stmts.add newCall(newDotExpr(buf, ident"add"),
                            newCall(ident"escapeHtml", newCall(ident"$", tmp)))
        else:
          stmts.add newCall(newDotExpr(buf, ident"add"),
                            newCall(ident"escapeHtml", newCall(ident"$", attrVal)))
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
        processNode(child, stmts, buf, lit)
      else:
        processContent(child, stmts, buf, lit)
    lit.add "</" & htmlTag & ">"

proc processNode(node: NimNode, stmts: NimNode, buf: NimNode, lit: var string) =
  case node.kind
  of nnkStmtList:
    for child in node:
      processNode(child, stmts, buf, lit)

  of nnkCall, nnkCommand:
    let firstName = resolveTagName(node[0])
    if isTag(firstName):
      processTag(node, firstName, stmts, buf, lit)
    elif node[0].kind == nnkIdent and node[0].strVal == "raw":
      # raw — insert without escaping
      flushLit(stmts, buf, lit)
      let content = if node.len > 1 and node[1].kind == nnkStmtList: node[1][0]
                    elif node.len > 1: node[1]
                    else: newStrLitNode("")
      if content.kind in {nnkCall, nnkCommand}:
        let tmp = genSym(nskLet, "raw")
        stmts.add newLetStmt(tmp, content)
        stmts.add newCall(newDotExpr(buf, ident"add"), tmp)
      else:
        stmts.add newCall(newDotExpr(buf, ident"add"), content)
    elif node[0].kind == nnkIdent and node[0].strVal == "text":
      # text — insert with escaping
      flushLit(stmts, buf, lit)
      let content = if node.len > 1 and node[1].kind == nnkStmtList: node[1][0]
                    elif node.len > 1: node[1]
                    else: newStrLitNode("")
      addDynamic(stmts, buf, content)
    elif node[0].kind == nnkIdent and node[0].strVal == "inject":
      # inject — call a {.buf.} layout, filling its named inject blocks
      # AST: Command("inject", Call(Name, args...), StmtList(->S1: body, ->S2: body, ...))
      # Body is a sibling of the Call node (node[2])
      flushLit(stmts, buf, lit)
      let call = if node.len > 1: node[1] else: return
      if call.kind in {nnkCall, nnkCommand}:
        let implName = layoutImplName(call[0].strVal)
        var implCall = newCall(implName, ident"ctx", buf)
        # Add all call arguments
        for i in 1..<call.len:
          implCall.add call[i]
        # Parse named inject blocks from body: ->S1: body, ->S2: body, ...
        # Each inject block becomes a closure: proc(ctx: Context, buf: var string)
        if node.len > 2 and node[2].kind == nnkStmtList:
          for injectBlkNode in node[2]:
            if injectBlkNode.kind == nnkPrefix and injectBlkNode[0].strVal == "->":
              # ->Sn: body — process body through DSL, wrap in lambda
              var injectBlkStmts = newStmtList()
              var injectBlkLit = ""
              let injectBlkBuf = ident"buf"
              if injectBlkNode.len > 2 and injectBlkNode[2].kind == nnkStmtList:
                processNode(injectBlkNode[2], injectBlkStmts, injectBlkBuf, injectBlkLit)
                flushLit(injectBlkStmts, injectBlkBuf, injectBlkLit)
              let lambda = newNimNode(nnkLambda).add(
                newEmptyNode(),  # name
                newEmptyNode(),  # patterns
                newEmptyNode(),  # generic params
                newNimNode(nnkFormalParams).add(
                  newEmptyNode(),  # void return
                  newIdentDefs(ident"ctx", ident"Context"),
                  newIdentDefs(injectBlkBuf, newNimNode(nnkVarTy).add(ident"string"))
                ),
                newEmptyNode(),  # pragmas
                newEmptyNode(),  # reserved
                injectBlkStmts       # body
              )
              implCall.add lambda
            else:
              # Non-inject-block content — process as regular DSL
              processNode(injectBlkNode, stmts, buf, lit)
              flushLit(stmts, buf, lit)
        stmts.add implCall
    else:
      # Not a tag — treat as expression
      processContent(node, stmts, buf, lit)

  of nnkPrefix:
    if node[0].kind == nnkIdent and node[0].strVal == "<-":
      # <-S1 — named inject block, calls __inject__S1(ctx, buf) at this position
      flushLit(stmts, buf, lit)
      stmts.add newCall(injectBlockName(node[1].strVal), ident"ctx", buf)
    else:
      flushLit(stmts, buf, lit)
      stmts.add node

  of nnkIdent:
    let name = node.strVal
    if isTag(name) and isVoid(name):
      # Only void tags can be bare identifiers (e.g., Br, Hr)
      # Non-void bare identifiers are treated as variables
      lit.add "<" & tagToHtml(name) & "/>"
    else:
      processContent(node, stmts, buf, lit)

  of nnkAccQuoted:
    let name = if node.len > 0: node[0].strVal else: ""
    if isTag(name) and isVoid(name):
      lit.add "<" & tagToHtml(name) & "/>"
    else:
      processContent(node, stmts, buf, lit)

  of nnkIfStmt, nnkIfExpr:
    flushLit(stmts, buf, lit)
    var ifNode = newNimNode(nnkIfStmt)
    for branch in node:
      case branch.kind
      of nnkElifBranch, nnkElifExpr:
        var body = newStmtList()
        processNode(branch[1], body, buf, lit)
        flushLit(body, buf, lit)
        ifNode.add newNimNode(nnkElifBranch).add(branch[0], body)
      of nnkElse, nnkElseExpr:
        var body = newStmtList()
        processNode(branch[0], body, buf, lit)
        flushLit(body, buf, lit)
        ifNode.add newNimNode(nnkElse).add(body)
      else: discard
    stmts.add ifNode

  of nnkForStmt:
    flushLit(stmts, buf, lit)
    var body = newStmtList()
    processNode(node[^1], body, buf, lit)
    flushLit(body, buf, lit)
    var forNode = newNimNode(nnkForStmt)
    for i in 0..<node.len - 1:
      forNode.add node[i]
    forNode.add body
    stmts.add forNode

  of nnkWhileStmt:
    flushLit(stmts, buf, lit)
    var body = newStmtList()
    processNode(node[1], body, buf, lit)
    flushLit(body, buf, lit)
    stmts.add newNimNode(nnkWhileStmt).add(node[0], body)

  of nnkCaseStmt:
    flushLit(stmts, buf, lit)
    var caseNode = newNimNode(nnkCaseStmt)
    caseNode.add node[0]
    for i in 1..<node.len:
      let branch = node[i]
      case branch.kind
      of nnkOfBranch:
        var body = newStmtList()
        processNode(branch[^1], body, buf, lit)
        flushLit(body, buf, lit)
        var ofNode = newNimNode(nnkOfBranch)
        for j in 0..<branch.len - 1:
          ofNode.add branch[j]
        ofNode.add body
        caseNode.add ofNode
      of nnkElse:
        var body = newStmtList()
        processNode(branch[0], body, buf, lit)
        flushLit(body, buf, lit)
        caseNode.add newNimNode(nnkElse).add(body)
      else: discard
    stmts.add caseNode

  of nnkTryStmt:
    flushLit(stmts, buf, lit)
    var tryNode = newNimNode(nnkTryStmt)
    var tryBody = newStmtList()
    processNode(node[0], tryBody, buf, lit)
    flushLit(tryBody, buf, lit)
    tryNode.add tryBody
    for i in 1..<node.len:
      let branch = node[i]
      case branch.kind
      of nnkExceptBranch:
        var body = newStmtList()
        processNode(branch[^1], body, buf, lit)
        flushLit(body, buf, lit)
        var exceptNode = newNimNode(nnkExceptBranch)
        for j in 0..<branch.len - 1:
          exceptNode.add branch[j]
        exceptNode.add body
        tryNode.add exceptNode
      of nnkFinally:
        var body = newStmtList()
        processNode(branch[0], body, buf, lit)
        flushLit(body, buf, lit)
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
    processContent(node, stmts, buf, lit)

proc countStaticLen*(stmts: NimNode): int =
  ## Count total static string length for pre-allocation estimate.
  for stmt in stmts:
    if stmt.kind == nnkCall and stmt.len > 1 and stmt[^1].kind == nnkStrLit:
      if stmt[0].kind == nnkDotExpr and stmt[0][1].eqIdent("add"):
        result += stmt[^1].strVal.len
    for child in stmt:
      if child.kind == nnkStmtList:
        result += countStaticLen(child)
      elif child.kind in {nnkElifBranch, nnkOfBranch}:
        if child[^1].kind == nnkStmtList:
          result += countStaticLen(child[^1])
      elif child.kind in {nnkElse}:
        if child[0].kind == nnkStmtList:
          result += countStaticLen(child[0])

proc countDynamicExprs*(stmts: NimNode): int =
  ## Count dynamic (non-static) buf.add calls for buffer estimation.
  for stmt in stmts:
    if stmt.kind == nnkCall and stmt.len > 1:
      if stmt[0].kind == nnkDotExpr and stmt[0][1].eqIdent("add"):
        if stmt[^1].kind != nnkStrLit:
          inc result
    for child in stmt:
      if child.kind == nnkStmtList:
        result += countDynamicExprs(child)
      elif child.kind in {nnkElifBranch, nnkOfBranch}:
        if child[^1].kind == nnkStmtList:
          result += countDynamicExprs(child[^1])
      elif child.kind in {nnkElse}:
        if child[0].kind == nnkStmtList:
          result += countDynamicExprs(child[0])

proc collectNestedCaps*(body: NimNode): seq[NimNode] =
  ## Find containered Name(...) calls in the original body and return Name_staticCap idents.
  case body.kind
  of nnkCommand:
    if body[0].kind == nnkIdent and body[0].strVal == "containered":
      let call = body[1]
      if call.kind in {nnkCall, nnkCommand}:
        result.add ident(call[0].strVal & "_staticCap")
      # Also scan the block body if present
      if call.kind in {nnkCall, nnkCommand} and call[^1].kind == nnkStmtList:
        for child in call[^1]:
          result.add collectNestedCaps(child)
  else:
    for child in body:
      result.add collectNestedCaps(child)

proc generateHtmlBlock*(body: NimNode): NimNode =
  ## Generate HTML rendering code from DSL body. Called by the layout macro.
  let buf = genSym(nskVar, "htmlBuf")
  var stmts = newStmtList()
  var lit = ""

  processNode(body, stmts, buf, lit)
  flushLit(stmts, buf, lit)

  let staticLen = countStaticLen(stmts)
  let cap = staticLen + 256

  var resultStmts = newStmtList()
  resultStmts.add newVarStmt(buf, newCall(ident"newStringOfCap", newIntLitNode(cap)))
  for stmt in stmts:
    resultStmts.add stmt
  resultStmts.add buf

  result = newBlockStmt(newEmptyNode(), resultStmts)

proc generateHtmlBlockBuffered*(body: NimNode, buf: NimNode): NimNode =
  ## Generate HTML rendering code that writes to an existing buffer.
  ## Unlike generateHtmlBlock, does not create or return the buffer.
  var stmts = newStmtList()
  var lit = ""
  processNode(body, stmts, buf, lit)
  flushLit(stmts, buf, lit)
  result = stmts
