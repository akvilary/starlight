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
import starlight/form
import starlight/urls
import starlight/server
import starlight/redis
import starlight/session
import starlight/memory_store
import starlight/redis_store

export types, context, router, middleware, escape, layout, handler, route, cdn, form, urls, server
export redis, session, memory_store, redis_store
