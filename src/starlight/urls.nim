## Type-safe URL builder with compile-time parameter validation.
##
## Parameters in {braces} are substituted from keyword arguments.
## Type annotations ({id:int}) cause automatic ``$`` conversion.
## Extra keyword arguments become URL-encoded query parameters.
## Missing parameters are caught at compile time.
##
##   mkUrl("/users/{name}", name = "alice")                        # "/users/alice"
##   mkUrl("/posts/{id:int}", id = 42)                             # "/posts/42"
##   mkUrl("/search", q = "hello world")                           # "/search?q=hello+world"
##   mkUrl("https://api.example.com/users/{id:int}", id = 1)       # external URL
##   mkUrl("/users/{name}", name = n, tab = "posts")               # "/users/" & n & "?tab=posts"

import std/[macros, strutils, uri]

macro mkUrl*(pattern: static string, args: varargs[untyped]): untyped =
  ## Builds a URL from a pattern and keyword arguments.
  ##
  ## Parameters ({name}, {id:int}, {active:bool}) are substituted
  ## from matching keyword args. Non-string params are converted via $.
  ## Extra keyword args become query string parameters (URL-encoded).
  ## Missing parameters cause a compile-time error.
  ##
  ## Works with both internal paths and external URLs.

  # --- Parse parameters from pattern ---
  var pathParams: seq[(string, string)]  # (name, type)
  for part in pattern.split('/'):
    if part.startsWith("{") and part.endsWith("}"):
      let inner = part[1..^2]
      let colonIdx = inner.find(':')
      if colonIdx >= 0:
        pathParams.add (inner[0 ..< colonIdx], inner[colonIdx + 1 .. ^1])
      else:
        pathParams.add (inner, "string")

  # --- Collect keyword arguments ---
  var kwargs: seq[(string, NimNode)]
  for arg in args:
    if arg.kind != nnkExprEqExpr:
      error("mkUrl: arguments must be keyword pairs (name = value)", arg)
    kwargs.add (arg[0].strVal, arg[1])

  # --- Validate: every pattern param has a matching kwarg ---
  var pathParamNames: seq[string]
  for (name, _) in pathParams:
    pathParamNames.add name
    block found:
      for (kw, _) in kwargs:
        if kw == name: break found
      error("mkUrl: missing parameter '" & name &
            "' required by \"" & pattern & "\"")

  # --- Separate query params (kwargs not consumed by pattern) ---
  var queryParams: seq[(string, NimNode)]
  for (name, value) in kwargs:
    if name notin pathParamNames:
      queryParams.add (name, value)

  # --- Build string expression as & chain ---
  let encUrl = bindSym"encodeUrl"
  var expr: NimNode

  proc add(node: NimNode) =
    if expr.isNil: expr = node
    else: expr = infix(expr, "&", node)

  var pos = 0
  var buf = ""
  while pos < pattern.len:
    if pattern[pos] == '{':
      if buf.len > 0:
        add newStrLitNode(buf)
        buf = ""
      inc pos
      let start = pos
      while pos < pattern.len and pattern[pos] != '}': inc pos
      let inner = pattern[start ..< pos]
      inc pos  # skip '}'
      let colonIdx = inner.find(':')
      let pName = if colonIdx >= 0: inner[0 ..< colonIdx] else: inner
      let pType = if colonIdx >= 0: inner[colonIdx + 1 .. ^1] else: "string"
      for (kw, val) in kwargs:
        if kw == pName:
          add(if pType == "string": val else: newCall(ident"$", val))
          break
    else:
      buf.add pattern[pos]
      inc pos

  if buf.len > 0:
    add newStrLitNode(buf)

  # Append query string
  if queryParams.len > 0:
    add newStrLitNode("?")
    for j, (name, value) in queryParams:
      if j > 0: add newStrLitNode("&")
      add newStrLitNode(name & "=")
      add newCall(encUrl, newCall(ident"$", value))

  if expr.isNil:
    expr = newStrLitNode("")
  result = expr
