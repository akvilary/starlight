## PrefixTree-based router with typed path parameters.

import std/[tables, options, strutils]
import types

proc newRouter*(): Router =
  Router(root: PrefixTreeNode(kind: skStatic, segment: ""))

proc parsePattern*(pattern: string): seq[PatternSegment] =
  let stripped = pattern.strip(chars = {'/'})
  if stripped == "":
    return @[]
  for part in stripped.split('/'):
    if part.startsWith("{") and part.endsWith("}"):
      let inner = part[1..^2]
      let colonIdx = inner.find(':')
      if colonIdx >= 0:
        let name = inner[0..<colonIdx]
        let typeStr = inner[colonIdx + 1..^1]
        let paramKind = case typeStr
          of "int": pkInt
          of "float": pkFloat
          of "bool": pkBool
          else: pkString
        result.add PatternSegment(name: name, kind: skParam, paramKind: paramKind)
      else:
        result.add PatternSegment(name: inner, kind: skParam, paramKind: pkString)
    elif part == "*":
      result.add PatternSegment(name: "", kind: skWildcard)
    else:
      result.add PatternSegment(name: part, kind: skStatic)

proc addRoute*(router: Router, httpMethod: HttpMethod, pattern: string,
               handler: HandlerProc, middlewares: seq[MiddlewareProc] = @[]) =
  let segments = parsePattern(pattern)
  var node = router.root
  for seg in segments:
    var found = false
    for child in node.children:
      if child.kind == seg.kind and child.segment == seg.name and
         (child.kind != skParam or child.paramKind == seg.paramKind):
        node = child
        found = true
        break
    if not found:
      let newNode = PrefixTreeNode(
        segment: seg.name,
        kind: seg.kind,
        paramKind: seg.paramKind,
      )
      node.children.add newNode
      node = newNode
  node.handlers[httpMethod] = HandlerEntry(
    handler: handler,
    middlewares: middlewares,
  )

proc validateParam(value: string, kind: ParamKind): bool =
  case kind
  of pkString: true
  of pkInt:
    try: discard parseInt(value); true
    except: false
  of pkFloat:
    try: discard parseFloat(value); true
    except: false
  of pkBool:
    value in ["true", "false", "1", "0"]

proc match*(router: Router, httpMethod: HttpMethod, path: string): Option[MatchResult] =
  let stripped = path.strip(chars = {'/'})
  let segments = if stripped == "": @[] else: stripped.split('/')
  var params: Table[string, string] = initTable[string, string]()

  proc matchRec(node: PrefixTreeNode, idx: int): Option[PrefixTreeNode] =
    if idx >= segments.len:
      if httpMethod in node.handlers:
        return some(node)
      return none(PrefixTreeNode)

    let seg = segments[idx]

    # Static children first (most specific)
    for child in node.children:
      if child.kind == skStatic and child.segment == seg:
        let r = matchRec(child, idx + 1)
        if r.isSome: return r

    # Param children
    for child in node.children:
      if child.kind == skParam and validateParam(seg, child.paramKind):
        params[child.segment] = seg
        let r = matchRec(child, idx + 1)
        if r.isSome: return r
        params.del(child.segment)

    # Wildcard children
    for child in node.children:
      if child.kind == skWildcard:
        let r = matchRec(child, idx + 1)
        if r.isSome: return r

    return none(PrefixTreeNode)

  let matched = matchRec(router.root, 0)
  if matched.isSome:
    let node = matched.get
    try:
      let entry = node.handlers[httpMethod]
      return some(MatchResult(
        handler: entry.handler,
        params: params,
        middlewares: entry.middlewares,
      ))
    except KeyError:
      discard
  return none(MatchResult)
