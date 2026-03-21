## In-memory session store.

import std/tables
import types, session

type
  MemorySessionStore* = ref object of SessionStore
    sessions*: Table[string, Table[string, SessionValue]]

proc newMemoryStore*(): MemorySessionStore =
  MemorySessionStore()

method load*(
  store: MemorySessionStore,
  id: string,
): Future[Session] {.async: (raises: [CatchableError]), gcsafe.} =
  if id.len > 0 and id in store.sessions:
    return Session(id: id, data: store.sessions[id])
  return Session(id: generateSessionId(), isNew: true)

method save*(
  store: MemorySessionStore,
  session: Session,
): Future[void] {.async: (raises: [CatchableError]), gcsafe.} =
  if session.isModified or session.isNew:
    store.sessions[session.id] = session.data

method destroy*(
  store: MemorySessionStore,
  session: Session,
): Future[void] {.async: (raises: [CatchableError]), gcsafe.} =
  store.sessions.del(session.id)
