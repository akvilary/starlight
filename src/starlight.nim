## Starlight — Super fast server-side rendering framework for Nim.
##
## Features:
## - Compile-time HTML DSL with static/dynamic splitting
## - PrefixTree router with typed path parameters
## - Middleware chain with explicit next
## - Zero-overhead HTML components

import starlight/types
import starlight/context
import starlight/router
import starlight/middleware
import starlight/private/escape
import starlight/component
import starlight/handler
import starlight/route
import starlight/server

export types, context, router, middleware, escape, component, handler, route, server
