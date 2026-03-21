## Redis-backed session store.

import std/[tables, strutils]
import types, session, redis

type
  RedisSessionStore* = ref object of SessionStore
    client*: RedisClient
    prefix*: string

proc serializeSession*(data: Table[string, SessionValue]): string =
  for key, val in data:
    result &= key & "\t"
    case val.kind
    of svkString: result &= "s:" & val.strVal
    of svkInt: result &= "i:" & $val.intVal
    of svkFloat: result &= "f:" & $val.floatVal
    of svkBool: result &= "b:" & $val.boolVal
    result &= "\n"

proc deserializeSession*(s: string): Table[string, SessionValue] =
  if s.len == 0: return
  for line in s.split("\n"):
    if line.len == 0: continue
    let tab = line.find('\t')
    if tab < 0: continue
    let key = line[0..<tab]
    let raw = line[tab+1..^1]
    if raw.len < 2: continue
    let prefix = raw[0..1]
    let val = raw[2..^1]
    result[key] = case prefix
      of "s:": SessionValue(kind: svkString, strVal: val)
      of "i:": SessionValue(kind: svkInt, intVal: parseInt(val))
      of "f:": SessionValue(kind: svkFloat, floatVal: parseFloat(val))
      of "b:": SessionValue(kind: svkBool, boolVal: parseBool(val))
      else: SessionValue(kind: svkString, strVal: raw)

proc newRedisStore*(
  host = "127.0.0.1",
  port = 6379,
  prefix = "session:",
): RedisSessionStore =
  RedisSessionStore(
    client: newRedisClient(host, port),
    prefix: prefix,
  )

method load*(
  store: RedisSessionStore,
  id: string,
): Future[Session] {.async: (raises: [CatchableError]), gcsafe.} =
  if id.len > 0:
    let raw = await store.client.get(store.prefix & id)
    if raw.len > 0:
      return Session(id: id, data: deserializeSession(raw))
  return Session(id: generateSessionId(), isNew: true)

method save*(
  store: RedisSessionStore,
  session: Session,
): Future[void] {.async: (raises: [CatchableError]), gcsafe.} =
  if session.isModified or session.isNew:
    await store.client.set(
      store.prefix & session.id,
      serializeSession(session.data),
    )

method destroy*(
  store: RedisSessionStore,
  session: Session,
): Future[void] {.async: (raises: [CatchableError]), gcsafe.} =
  await store.client.del(store.prefix & session.id)
