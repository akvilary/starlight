## Static file serving and CDN proxy.

import std/[os, sets, strutils, options]
import chronos
import chronos/apps/http/[httpserver, httpclient]
import types

proc getMimeType*(ext: string): string =
  case ext
  of "html": "text/html"
  of "css": "text/css"
  of "js": "application/javascript"
  of "json": "application/json"
  of "png": "image/png"
  of "jpg", "jpeg": "image/jpeg"
  of "svg": "image/svg+xml"
  of "gif": "image/gif"
  of "ico": "image/x-icon"
  of "woff2": "font/woff2"
  of "woff": "font/woff"
  of "ttf": "font/ttf"
  of "pdf": "application/pdf"
  of "xml": "application/xml"
  of "txt": "text/plain"
  of "webp": "image/webp"
  of "mp4": "video/mp4"
  of "webm": "video/webm"
  of "mp3": "audio/mpeg"
  of "zip": "application/zip"
  else: "application/octet-stream"

proc addCDN*(router: Router, path: string,
             extensions: openArray[string] = []) =
  router.cdnDirs.add CDNEntry(
    path: path.strip(chars = {'/'}),
    extensions: extensions.toHashSet(),
  )

proc addCDN*(router: Router, path: string, proxy: string,
             extensions: openArray[string] = []) =
  router.cdnDirs.add CDNEntry(
    path: path.strip(chars = {'/'}),
    proxy: proxy.strip(chars = {'/'}),
    extensions: extensions.toHashSet(),
  )

proc tryServeStatic(entry: CDNEntry, reqPath: string): Option[Response] =
  let prefix = "/" & entry.path
  if not reqPath.startsWith(prefix):
    return none(Response)

  let relative = reqPath[prefix.len..^1].strip(chars = {'/'})
  if relative.len == 0:
    return none(Response)

  # Security: reject path traversal
  if ".." in relative:
    return none(Response)

  let baseDir = absolutePath(entry.path).normalizedPath()
  let filePath = absolutePath(entry.path / relative).normalizedPath()

  # Security: verify resolved path stays inside the base directory
  if not filePath.startsWith(baseDir):
    return none(Response)

  if not fileExists(filePath):
    return none(Response)

  # Check file is regular (not symlink escaping)
  let info = getFileInfo(filePath)
  if info.kind != pcFile:
    return none(Response)

  # Extension filter
  let ext = filePath.splitFile().ext.strip(chars = {'.'}).toLowerAscii()
  if entry.extensions.len > 0 and ext notin entry.extensions:
    return none(Response)

  let body = readFile(filePath)
  let mime = getMimeType(ext)
  some(Response(
    code: Http200,
    body: body,
    headers: HttpTable.init([("Content-Type", mime)]),
  ))

proc tryProxyCDN(entry: CDNEntry,
                 reqPath: string): Future[Option[Response]] {.
    async: (raises: [CatchableError]).} =
  let prefix = "/" & entry.path
  if not reqPath.startsWith(prefix):
    return none(Response)

  let relative = reqPath[prefix.len..^1].strip(leading = false, chars = {'/'})
  if relative.len == 0:
    return none(Response)

  # Extension filter
  let ext = relative.splitFile().ext.strip(chars = {'.'}).toLowerAscii()
  if entry.extensions.len > 0 and ext notin entry.extensions:
    return none(Response)

  let targetUrl = entry.proxy & relative
  let session = HttpSessionRef.new()
  try:
    let resp = await session.fetch(parseUri(targetUrl))
    let mime = getMimeType(ext)
    return some(Response(
      code: HttpCode(resp.status),
      body: cast[string](resp.data),
      headers: HttpTable.init([("Content-Type", mime)]),
    ))
  except CatchableError:
    return none(Response)
  finally:
    await session.closeWait()

proc tryServeCDN*(router: Router, path: string): Future[Option[Response]] {.
    async: (raises: [CatchableError]).} =
  # Try local files first
  for entry in router.cdnDirs:
    if entry.proxy.len == 0:
      let resp = tryServeStatic(entry, path)
      if resp.isSome:
        return resp

  # Then try proxy entries
  for entry in router.cdnDirs:
    if entry.proxy.len > 0:
      let resp = await tryProxyCDN(entry, path)
      if resp.isSome:
        return resp

  return none(Response)
