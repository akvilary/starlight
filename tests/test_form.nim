import std/[unittest, tables]
import ../src/starlight

suite "parseQueryString":
  test "basic key-value pairs":
    let result = parseQueryString("name=alice&age=30")
    check result["name"] == "alice"
    check result["age"] == "30"

  test "URL-decoded values":
    let result = parseQueryString("q=hello+world&path=%2Ffoo%2Fbar")
    check result["q"] == "hello world"
    check result["path"] == "/foo/bar"

  test "empty value":
    let result = parseQueryString("key=&other=val")
    check result["key"] == ""
    check result["other"] == "val"

  test "key without value":
    let result = parseQueryString("flag")
    check result["flag"] == ""

  test "empty string":
    let result = parseQueryString("")
    check result.len == 0

suite "formData — URL-encoded":
  test "parses URL-encoded body":
    let headers = HttpTable.init([
      ("content-type", "application/x-www-form-urlencoded"),
    ])
    let form = parseFormData("username=alice&password=secret", headers)
    check form["username"] == "alice"
    check form["password"] == "secret"

  test "URL-decoded values in form body":
    let headers = HttpTable.init([
      ("content-type", "application/x-www-form-urlencoded"),
    ])
    let form = parseFormData("name=John+Doe&city=New%20York", headers)
    check form["name"] == "John Doe"
    check form["city"] == "New York"

suite "formData — multipart":
  test "parses text fields":
    let boundary = "----boundary123"
    let body = "------boundary123\r\n" &
      "Content-Disposition: form-data; name=\"title\"\r\n" &
      "\r\n" &
      "Hello World\r\n" &
      "------boundary123\r\n" &
      "Content-Disposition: form-data; name=\"desc\"\r\n" &
      "\r\n" &
      "A description\r\n" &
      "------boundary123--\r\n"
    let headers = HttpTable.init([
      ("content-type", "multipart/form-data; boundary=" & boundary),
    ])
    let form = parseFormData(body, headers)
    check form["title"] == "Hello World"
    check form["desc"] == "A description"

  test "parses file upload":
    let boundary = "----boundary456"
    let fileContent = "fake image data"
    let body = "------boundary456\r\n" &
      "Content-Disposition: form-data; name=\"photo\"; filename=\"pic.jpg\"\r\n" &
      "Content-Type: image/jpeg\r\n" &
      "\r\n" &
      fileContent & "\r\n" &
      "------boundary456--\r\n"
    let headers = HttpTable.init([
      ("content-type", "multipart/form-data; boundary=" & boundary),
    ])
    let form = parseFormData(body, headers)
    check form.hasFile("photo")
    let f = form.file("photo")
    check f.filename == "pic.jpg"
    check f.contentType == "image/jpeg"
    check f.data == @(fileContent.toOpenArrayByte(0, fileContent.len - 1))

  test "mixed text fields and file uploads":
    let boundary = "----mix789"
    let body = "------mix789\r\n" &
      "Content-Disposition: form-data; name=\"title\"\r\n" &
      "\r\n" &
      "My Photo\r\n" &
      "------mix789\r\n" &
      "Content-Disposition: form-data; name=\"file\"; filename=\"photo.png\"\r\n" &
      "Content-Type: image/png\r\n" &
      "\r\n" &
      "PNG_DATA\r\n" &
      "------mix789--\r\n"
    let headers = HttpTable.init([
      ("content-type", "multipart/form-data; boundary=" & boundary),
    ])
    let form = parseFormData(body, headers)
    check form["title"] == "My Photo"
    check form.hasFile("file")
    check form.file("file").filename == "photo.png"

suite "FormData accessors":
  test "getField with default":
    let headers = HttpTable.init([
      ("content-type", "application/x-www-form-urlencoded"),
    ])
    let form = parseFormData("name=alice", headers)
    check form.getField("name") == "alice"
    check form.getField("missing", "default") == "default"

  test "hasField and hasFile":
    let headers = HttpTable.init([
      ("content-type", "application/x-www-form-urlencoded"),
    ])
    let form = parseFormData("key=val", headers)
    check form.hasField("key")
    check not form.hasField("missing")
    check not form.hasFile("key")

  test "missing key raises KeyError":
    let form = parseFormData("", HttpTable.init())
    expect(KeyError):
      discard form["missing"]
    expect(KeyError):
      discard form.file("missing")

suite "formData — edge cases":
  test "missing Content-Type returns empty FormData":
    let form = parseFormData("data=value", HttpTable.init())
    check form.fields.len == 0

  test "unsupported Content-Type returns empty FormData":
    let headers = HttpTable.init([
      ("content-type", "application/json"),
    ])
    let form = parseFormData("{}", headers)
    check form.fields.len == 0

  test "empty body with URL-encoded type":
    let headers = HttpTable.init([
      ("content-type", "application/x-www-form-urlencoded"),
    ])
    let form = parseFormData("", headers)
    check form.fields.len == 0

suite "context integration":
  test "ctx.formData parses URL-encoded body":
    let ctx = newContext()
    ctx.request.headers = HttpTable.init([
      ("content-type", "application/x-www-form-urlencoded"),
    ])
    ctx.request.body = "user=bob&role=admin"
    let form = ctx.formData()
    check form["user"] == "bob"
    check form["role"] == "admin"
