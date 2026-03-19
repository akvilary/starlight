## Form data parsing for URL-encoded and multipart/form-data requests.

import std/[tables, strutils, uri]
import chronos/apps/http/[httptable, httpcommon, multipart]

type
  UploadFile* = object
    filename*: string
    contentType*: string
    data*: seq[byte]

  FormData* = ref object
    fields*: Table[string, string]
    files*: Table[string, UploadFile]

proc parseQueryString*(qs: string): Table[string, string] =
  result = initTable[string, string]()
  if qs.len == 0: return
  for pair in qs.split('&'):
    let eqIdx = pair.find('=')
    if eqIdx >= 0:
      result[decodeUrl(pair[0..<eqIdx])] = decodeUrl(pair[eqIdx + 1..^1])
    else:
      result[decodeUrl(pair)] = ""

proc parseDispositionParam(value: string, key: string): string =
  ## Extract a named parameter from Content-Disposition value.
  for param in value.split(';'):
    let trimmed = param.strip()
    if trimmed.toLowerAscii().startsWith(key & "=\""):
      let start = key.len + 2
      if trimmed.len > start and trimmed[^1] == '"':
        return trimmed[start..^2]

proc parseMultipart(body: string, boundary: string, form: FormData) =
  ## Parse multipart/form-data body. Works directly on the string body
  ## without copying into intermediate byte buffers.
  let delim = "--" & boundary
  var pos = body.find(delim)
  if pos < 0: return
  pos += delim.len

  while pos < body.len:
    # Skip \r\n after boundary
    if pos + 1 < body.len and body[pos] == '\r' and body[pos + 1] == '\n':
      pos += 2
    else:
      break

    # Find end of headers (\r\n\r\n)
    let headerEnd = body.find("\r\n\r\n", pos)
    if headerEnd < 0: break

    let headerSection = body[pos..<headerEnd]
    let dataStart = headerEnd + 4

    # Find next boundary
    let nextBoundary = body.find("\r\n" & delim, dataStart)
    if nextBoundary < 0: break

    let data = body[dataStart..<nextBoundary]

    # Parse part headers
    var name, filename, contentType: string
    for line in headerSection.split("\r\n"):
      let lower = line.toLowerAscii()
      if lower.startsWith("content-disposition:"):
        let value = line[20..^1]
        name = parseDispositionParam(value, "name")
        filename = parseDispositionParam(value, "filename")
      elif lower.startsWith("content-type:"):
        contentType = line[13..^1].strip()

    if name.len > 0:
      if filename.len > 0:
        form.files[name] = UploadFile(
          filename: filename,
          contentType: contentType,
          data: @(data.toOpenArrayByte(0, data.len - 1)),
        )
      else:
        form.fields[name] = data

    # Move past \r\n + delimiter
    pos = nextBoundary + 2 + delim.len
    # Check closing boundary (--)
    if pos + 1 < body.len and body[pos] == '-' and body[pos + 1] == '-':
      break

proc parseFormData*(
  body: string,
  headers: HttpTable,
): FormData =
  ## Parses form data from a request body based on Content-Type header.
  ## Supports application/x-www-form-urlencoded and multipart/form-data.
  ## Returns an empty FormData if Content-Type is missing or unsupported.
  result = FormData(
    fields: initTable[string, string](),
    files: initTable[string, UploadFile](),
  )

  let ctList = headers.getList("content-type")
  if ctList.len == 0:
    return

  let ctResult = getContentType(ctList)
  if ctResult.isErr():
    return

  let ct = ctResult.get()

  if ct == UrlEncodedContentType:
    result.fields = parseQueryString(body)
  elif ct == MultipartContentType:
    let boundaryResult = getMultipartBoundary(ct)
    if boundaryResult.isErr():
      return
    parseMultipart(body, boundaryResult.get(), result)

# --- Accessors ---

proc `[]`*(form: FormData, key: string): string =
  form.fields[key]

proc getField*(
  form: FormData,
  key: string,
  default: string = "",
): string =
  form.fields.getOrDefault(key, default)

proc file*(form: FormData, key: string): UploadFile =
  form.files[key]

proc hasField*(form: FormData, key: string): bool =
  key in form.fields

proc hasFile*(form: FormData, key: string): bool =
  key in form.files
