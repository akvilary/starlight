## Type-safe URL builders with compile-time parameter validation.
##
## ``urlAs`` — build a URL from a pattern string:
##   urlAs("/users/{name}", name = "alice")               # "/users/alice"
##   urlAs("/posts/{id:int}", id = 42)                    # "/posts/42"
##   urlAs("/search", q = "hello world")                  # "/search?q=hello+world"
##   urlAs("/users/{name}", RelRef, name = "alice")       # "./users/alice"
##
## ``urlFor`` — build a URL from a Route entity:
##   urlFor(userShow, name = "alice")                     # "/users/alice"
##   urlFor(userShow, RelRef, name = "alice")             # "./users/alice"

import std/[macros, strutils, uri]

# --- Shared helpers (compile-time) ---

proc collectKwargs*(
  args: NimNode,
  startIdx: int,
  macroName: string,
): seq[(string, NimNode)] =
  ## Collects keyword arguments from macro args starting at startIdx.
  for i in startIdx ..< args.len:
    let arg = args[i]
    if arg.kind != nnkExprEqExpr:
      error(macroName & ": arguments must be keyword pairs (name = value)", arg)
    result.add (arg[0].strVal, arg[1])

proc detectRefKind*(args: NimNode): (bool, int) =
  ## Checks if the first arg is RelRef or AbsRef.
  ## Returns (isRelative, startIdx for kwargs).
  if args.len > 0 and args[0].kind == nnkIdent:
    let name = args[0].strVal
    if name == "RelRef":
      return (true, 1)
    elif name == "AbsRef":
      return (false, 1)
  return (false, 0)

proc buildUrlExpr*(
  pattern: string,
  kwargs: seq[(string, NimNode)],
  macroName: string,
  relative: bool,
): NimNode =
  ## Builds a URL string expression from a pattern and keyword arguments.
  ## Shared by urlAs and urlFor.

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

  # --- Validate: every pattern param has a matching kwarg ---
  var pathParamNames: seq[string]
  for (name, _) in pathParams:
    pathParamNames.add name
    block found:
      for (kw, _) in kwargs:
        if kw == name: break found
      error(macroName & ": missing parameter '" & name &
            "' required by \"" & pattern & "\"")

  # --- Separate query params (kwargs not consumed by pattern) ---
  var queryParams: seq[(string, NimNode)]
  for (name, value) in kwargs:
    if name notin pathParamNames:
      queryParams.add (name, value)

  # --- Apply relative mode ---
  # "./" prefix → already relative, keep as-is
  # "/" prefix + RelRef → convert to "./"
  let effectivePattern = if pattern.startsWith("./"):
    pattern                    # already relative, no double "./"
  elif relative and pattern.startsWith("/"):
    "./" & pattern[1 .. ^1]    # RelRef on absolute: "/{name}" → "./{name}"
  elif relative:
    "./" & pattern
  else:
    pattern

  # --- Build string expression as & chain ---
  let encUrl = bindSym"encodeUrl"
  var expr: NimNode

  proc add(node: NimNode) =
    if expr.isNil: expr = node
    else: expr = infix(expr, "&", node)

  var pos = 0
  var buf = ""
  while pos < effectivePattern.len:
    if effectivePattern[pos] == '{':
      if buf.len > 0:
        add newStrLitNode(buf)
        buf = ""
      inc pos
      let start = pos
      while pos < effectivePattern.len and effectivePattern[pos] != '}': inc pos
      let inner = effectivePattern[start ..< pos]
      inc pos  # skip '}'
      let colonIdx = inner.find(':')
      let pName = if colonIdx >= 0: inner[0 ..< colonIdx] else: inner
      let pType = if colonIdx >= 0: inner[colonIdx + 1 .. ^1] else: "string"
      for (kw, val) in kwargs:
        if kw == pName:
          add(if pType == "string": val else: newCall(ident"$", val))
          break
    else:
      buf.add effectivePattern[pos]
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

# --- Public macros ---

macro urlAs*(pattern: static string, args: varargs[untyped]): untyped =
  ## Builds a URL from a pattern string and keyword arguments.
  ##
  ## Parameters ({name}, {id:int}) are substituted from keyword args.
  ## Extra keyword args become query string parameters (URL-encoded).
  ## Missing parameters cause a compile-time error.
  ## Optional first arg: RelRef for relative URLs, AbsRef for absolute (default).
  ##
  ## Works with both internal paths and external URLs.
  let (relative, startIdx) = detectRefKind(args)
  let kwargs = collectKwargs(args, startIdx, "urlAs")
  result = buildUrlExpr(pattern, kwargs, "urlAs", relative)

macro urlFor*(route: typed, args: varargs[untyped]): untyped =
  ## Builds a URL from a RouteRef entity and keyword arguments.
  ##
  ## Extracts the pattern from RouteRef[P]'s type parameter at compile time.
  ## If the pattern starts with "./" the URL is relative by default.
  ## RelRef on absolute patterns converts "/" to "./".
  let typeInst = route.getTypeInst()
  if typeInst.kind != nnkBracketExpr or typeInst.len < 2:
    error("urlFor: argument must be a RouteRef[pattern]", route)
  let patternNode = typeInst[1]
  if patternNode.kind != nnkStrLit:
    error("urlFor: could not extract pattern from RouteRef type", route)
  let pattern = patternNode.strVal

  let (explicitRelative, startIdx) = detectRefKind(args)
  let kwargs = collectKwargs(args, startIdx, "urlFor")
  # "./" patterns are always relative; absolute patterns need explicit RelRef
  let relative = pattern.startsWith("./") or explicitRelative
  result = buildUrlExpr(pattern, kwargs, "urlFor", relative)
