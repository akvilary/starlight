## Core types for the SSR framework.

import std/[httpcore, tables, asyncdispatch]
export httpcore, tables, asyncdispatch

type
  ParamKind* = enum
    pkString, pkInt, pkFloat, pkBool

  SegmentKind* = enum
    skStatic, skParam, skWildcard

  PatternSegment* = object
    name*: string
    kind*: SegmentKind
    paramKind*: ParamKind

  Context* = ref object
    path*: string
    httpMethod*: HttpMethod
    headers*: HttpHeaders
    body*: string
    query*: Table[string, string]
    pathParams*: Table[string, string]
    ip*: string

  Response* = object
    code*: HttpCode
    body*: string
    headers*: HttpHeaders

  HandlerProc* = proc(ctx: Context): Future[Response] {.gcsafe.}

  MiddlewareProc* = proc(ctx: Context, next: HandlerProc): Future[Response] {.gcsafe.}

  HandlerEntry* = object
    handler*: HandlerProc
    middlewares*: seq[MiddlewareProc]

  PrefixTreeNode* = ref object
    segment*: string
    kind*: SegmentKind
    paramKind*: ParamKind
    children*: seq[PrefixTreeNode]
    handlers*: Table[HttpMethod, HandlerEntry]

  Router* = ref object
    root*: PrefixTreeNode

  MatchResult* = object
    handler*: HandlerProc
    params*: Table[string, string]
    middlewares*: seq[MiddlewareProc]

  RouteEntry* = object
    httpMethod*: HttpMethod
    pattern*: string
    handler*: HandlerProc
    middlewares*: seq[MiddlewareProc]

  RouteGroup* = object
    entries*: seq[RouteEntry]

  App* = ref object
    router*: Router
    globalMiddlewares*: seq[MiddlewareProc]
    notFoundHandler*: HandlerProc
