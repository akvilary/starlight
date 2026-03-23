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
