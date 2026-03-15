## Name mangling for generated layout procs/templates.

import std/macros

proc layoutImplName*(name: string): NimNode =
  ident("__layout__" & name)
