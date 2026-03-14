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

import std/macros
import html

macro layout*(signature: untyped, body: untyped): untyped =
  ## Generates an inline proc (with ctx: Context) and a template wrapper
  ## (without ctx) for implicit context passing.

  let name = signature[0]
  let implName = ident(name.strVal & "_impl")

  # Build param list for proc: ctx: Context, then user params
  var procParams: seq[NimNode] = @[]
  procParams.add ident"string"  # return type
  procParams.add newIdentDefs(ident"ctx", ident"Context")

  # Build param list for template: just user params (no ctx)
  var tmplParams: seq[NimNode] = @[]
  tmplParams.add ident"string"  # return type

  # Collect call args for template -> proc forwarding
  var callArgs: seq[NimNode] = @[]
  callArgs.add ident"ctx"  # first arg is ctx from caller's scope

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

  # proc Name_impl*(ctx: Context, ...): string {.inline.} = generateHtmlBlock(body)
  let implProc = newProc(
    name = postfix(implName, "*"),
    params = procParams,
    body = newStmtList(generateHtmlBlock(body)),
    procType = nnkProcDef,
  )
  implProc.addPragma(ident"inline")

  # template Name*(...): string = Name_impl(ctx, ...)
  let forwardCall = newCall(implName, callArgs)
  let tmpl = newProc(
    name = postfix(name, "*"),
    params = tmplParams,
    body = newStmtList(forwardCall),
    procType = nnkTemplateDef,
  )

  result = newStmtList(implProc, tmpl)
