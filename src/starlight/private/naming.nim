## Name mangling for generated layout procs/templates.

import std/[macros, macrocache]

type
  LazyKind* = enum
    lkSingle  ## single lazy closure (mangled: __lazy__name)
    lkSeq     ## openArray of lazy closures (mangled: __lazy__name)
    lkRaw     ## unmangled closure (for-loop variable over seq lazy param)

  LazyParam* = object
    name*: string
    kind*: LazyKind
    typeName*: string

  LazyInfo* = tuple[kind: LazyKind, typeName: string]

const lazyTypeRegistry* = CacheTable"lazyTypeRegistry"

proc layoutImplName*(name: string): NimNode =
  ident("__layout__" & name)

proc lazyParamName*(name: string): NimNode =
  ident("__lazy__" & name)

proc maybeExport*(name: NimNode, isExported: bool): NimNode =
  if isExported: postfix(name, "*") else: name

proc insertName(name, node: NimNode): NimNode =
  ## Reattach name into the params node produced by Nim's parser for `Name*(...)`.
  case node.kind
  of nnkPragmaExpr:
    result = newNimNode(nnkPragmaExpr).add(insertName(name, node[0]), node[1])
  of nnkTupleConstr:
    result = newNimNode(nnkObjConstr).add(name)
    for c in node: result.add c
  of nnkObjConstr:
    # [T](params) → Name[T](params)
    var be = newNimNode(nnkBracketExpr).add(name)
    for c in node[0]: be.add c
    result = newNimNode(nnkObjConstr).add(be)
    for i in 1..<node.len: result.add node[i]
  else:
    result = newCall(name)

proc normalizeExportMarker*(sig: NimNode): tuple[sig: NimNode, isExported: bool] =
  ## Strip `*` from `Name*(args)` and return normalized signature + export flag.
  if sig.kind != nnkInfix or sig[0].strVal != "*":
    return (sig, false)
  (insertName(sig[1], sig[2]), true)
