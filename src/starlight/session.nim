## Session API and store interface.
##
## Usage:
##   var store = newMemoryStore()
##   router.use(withSessions(store))
##
##   handler dashboard(ctx: Context) {.html.}:
##     let name = ctx.session.get("name", "guest")
##     return "Hello, " & name

import std/[tables, strutils, sysrand]
import types, context

# --- Session API ---

proc get*(s: Session, key: string, default: string = ""): string =
  if key in s.data:
    let v = s.data[key]
    if v.kind == svkString: return v.strVal
  return default

proc get*(s: Session, key: string, _: typedesc[int], default: int = 0): int =
  if key in s.data:
    let v = s.data[key]
    if v.kind == svkInt: return v.intVal
  return default

proc get*(
  s: Session,
  key: string,
  _: typedesc[float],
  default: float = 0.0,
): float =
  if key in s.data:
    let v = s.data[key]
    if v.kind == svkFloat: return v.floatVal
  return default

proc get*(
  s: Session,
  key: string,
  _: typedesc[bool],
  default: bool = false,
): bool =
  if key in s.data:
    let v = s.data[key]
    if v.kind == svkBool: return v.boolVal
  return default

proc set*(s: Session, key: string, value: string) =
  s.data[key] = SessionValue(kind: svkString, strVal: value)
  s.isModified = true

proc set*(s: Session, key: string, value: int) =
  s.data[key] = SessionValue(kind: svkInt, intVal: value)
  s.isModified = true

proc set*(s: Session, key: string, value: float) =
  s.data[key] = SessionValue(kind: svkFloat, floatVal: value)
  s.isModified = true

proc set*(s: Session, key: string, value: bool) =
  s.data[key] = SessionValue(kind: svkBool, boolVal: value)
  s.isModified = true

proc delete*(s: Session, key: string) =
  s.data.del(key)
  s.isModified = true

proc clear*(s: Session) =
  s.data.clear()
  s.isModified = true

# --- Session ID ---

proc generateSessionId*(): string =
  ## Generates a 32-char hex session ID from 128 bits of crypto-random.
  var bytes: array[16, byte]
  doAssert urandom(bytes), "Failed to generate random bytes"
  result = newStringOfCap(32)
  for b in bytes:
    result.add(b.toHex(2).toLowerAscii)

# --- Store interface (base methods) ---

method load*(
  store: SessionStore,
  id: string,
): Future[Session] {.async: (raises: [CatchableError]), base, gcsafe.} =
  return Session(id: generateSessionId(), isNew: true)

method save*(
  store: SessionStore,
  session: Session,
): Future[void] {.async: (raises: [CatchableError]), base, gcsafe.} =
  discard

method destroy*(
  store: SessionStore,
  session: Session,
): Future[void] {.async: (raises: [CatchableError]), base, gcsafe.} =
  discard

# --- Built-in session middleware ---

proc withSessions*(
  store: SessionStore,
  cookieName = "sid",
): MiddlewareProc =
  ## Returns a middleware that loads/saves sessions via the store.
  return proc(ctx: Context, next: HandlerProc): Future[Response] {.
      async: (raises: [CatchableError]), gcsafe.} =
    ctx.session = await store.load(ctx.cookies.get(cookieName))
    var res = await next(ctx)
    await store.save(ctx.session)
    if ctx.session.isNew:
      ctx.cookies.set(cookieName, ctx.session.id,
        httpOnly=true, secure=true, sameSite=Lax, path="/")
    return res
