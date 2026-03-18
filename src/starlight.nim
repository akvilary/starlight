## Starlight — Super fast server-side rendering framework for Nim.
##
## Features:
## - Compile-time HTML DSL with static/dynamic splitting
## - PrefixTree router with typed path parameters
## - Middleware chain with explicit next
## - Zero-overhead HTML components

import std/strutils as stdStrutils
import starlight/types
import starlight/context
import starlight/router
import starlight/middleware
import starlight/private/escape
import starlight/layout
import starlight/handler
import starlight/route
import starlight/cdn
import starlight/server

export types, context, router, middleware, escape, layout, handler, route, cdn, server
export stdStrutils.parseInt, stdStrutils.parseFloat, stdStrutils.parseBool
