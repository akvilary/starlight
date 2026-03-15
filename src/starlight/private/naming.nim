## Name mangling for generated layout procs/templates.

import std/macros

proc layoutImplName*(name: string): NimNode =
  ident("__layout__" & name)

proc lazyParamName*(name: string): NimNode =
  ident("__lazy__" & name)
