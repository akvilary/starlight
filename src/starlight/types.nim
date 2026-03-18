## Core types for the SSR framework.

import std/[tables, sets]
import chronos
import chronos/apps/http/httpserver

export tables, sets, chronos, httpserver

type
  ParamKind* = enum
    pkString, pkInt, pkFloat, pkBool

  SegmentKind* = enum
    skStatic, skParam, skWildcard

  PatternSegment* = object
    name*: string
    kind*: SegmentKind
    paramKind*: ParamKind

  RequestData* = ref object
    headers*: HttpTable
    body*: string
    query*: Table[string, string]
    ip*: string

  Context* = ref object
    path*: string
    httpMethod*: HttpMethod
    pathParams*: Table[string, string]
    request*: RequestData
    router*: Router

  Response* = object
    code*: HttpCode = Http200
    body*: string
    headers*: HttpTable

  HandlerProc* = proc(ctx: Context): Future[Response] {.
    async: (raises: [CatchableError]), gcsafe.}

  MiddlewareProc* = proc(ctx: Context, next: HandlerProc): Future[Response] {.
    async: (raises: [CatchableError]), gcsafe.}

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
    globalMiddlewares*: seq[MiddlewareProc]
    notFoundHandler*: HandlerProc
    cdnDirs*: seq[CDNEntry]

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

  CDNEntry* = object
    path*: string
    proxy*: string
    extensions*: HashSet[string]
