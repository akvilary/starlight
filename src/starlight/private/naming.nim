## Name mangling for generated layout procs/templates.

import std/macros

proc layoutImplName*(name: string): NimNode =
  ident("__layout__" & name)

proc injectBlockName*(name: string): NimNode =
  ident("__inject__" & name)
