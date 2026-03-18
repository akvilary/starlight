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

  let tail = reqPath[prefix.len..^1]
  # After prefix: must be empty (exact match) or start with /
  if tail.len > 0 and tail[0] != '/':
    return none(Response)

  let relative = tail.strip(chars = {'/'})

  let filePath =
    if relative.len == 0:
      # Exact file match: addCDN("/public/style.css") → GET /public/style.css
      absolutePath(entry.path).normalizedPath()
    else:
      # Security: reject path traversal
      if ".." in relative:
        return none(Response)
      let baseDir = absolutePath(entry.path).normalizedPath()
      let resolved = absolutePath(entry.path / relative).normalizedPath()
      # Security: verify resolved path stays inside the base directory
      if not resolved.startsWith(baseDir):
        return none(Response)
      resolved

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

  let tail = reqPath[prefix.len..^1]
  if tail.len > 0 and tail[0] != '/':
    return none(Response)

  let relative = tail.strip(leading = false, chars = {'/'})

  # Build target URL
  let targetUrl =
    if relative.len == 0:
      # Exact match: addCDN("/libs/vue.js", proxy = "https://cdn/vue.js")
      entry.proxy
    else:
      entry.proxy & relative

  # Extension filter
  let ext = targetUrl.splitFile().ext.strip(chars = {'.'}).toLowerAscii()
  if entry.extensions.len > 0 and ext notin entry.extensions:
    return none(Response)

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
  for entry in router.cdnDirs:
    if entry.proxy.len > 0:
      let resp = await tryProxyCDN(entry, path)
      if resp.isSome:
        return resp
    else:
      let resp = tryServeStatic(entry, path)
      if resp.isSome:
        return resp

  return none(Response)
