## Minimal async Redis client over chronos StreamTransport.
## Connects lazily on first command.

import std/strutils
import chronos, chronos/transports/stream

type
  RedisClient* = ref object
    transport*: StreamTransport
    host*: string
    port*: int
    isConnected*: bool

proc newRedisClient*(host = "127.0.0.1", port = 6379): RedisClient =
  RedisClient(host: host, port: port)

proc encodeCommand(args: openArray[string]): string =
  result = "*" & $args.len & "\r\n"
  for arg in args:
    result &= "$" & $arg.len & "\r\n" & arg & "\r\n"

proc ensureConnected*(
  client: RedisClient,
) {.async: (raises: [CatchableError]).} =
  if not client.isConnected:
    let address = initTAddress(client.host, client.port)
    client.transport = await connect(address)
    client.isConnected = true

proc sendCommand*(
  client: RedisClient,
  args: seq[string],
): Future[string] {.async: (raises: [CatchableError]).} =
  await client.ensureConnected()
  let cmd = encodeCommand(args)
  discard await client.transport.write(cmd)
  let line = await client.transport.readLine()
  if line.len == 0:
    return ""
  case line[0]
  of '+': return line[1..^1]
  of '-': raise newException(CatchableError, "Redis error: " & line[1..^1])
  of ':': return line[1..^1]
  of '$':
    let len = parseInt(line[1..^1])
    if len < 0: return ""
    var data = newString(len + 2)
    let bytesRead = await client.transport.readOnce(addr data[0], len + 2)
    if bytesRead >= len:
      return data[0..<len]
    return ""
  else: return ""

proc set*(
  client: RedisClient,
  key: string,
  value: string,
) {.async: (raises: [CatchableError]).} =
  discard await client.sendCommand(@["SET", key, value])

proc get*(
  client: RedisClient,
  key: string,
): Future[string] {.async: (raises: [CatchableError]).} =
  return await client.sendCommand(@["GET", key])

proc del*(
  client: RedisClient,
  key: string,
) {.async: (raises: [CatchableError]).} =
  discard await client.sendCommand(@["DEL", key])

proc close*(client: RedisClient) {.async: (raises: [CatchableError]).} =
  if client.isConnected:
    await client.transport.closeWait()
    client.isConnected = false
