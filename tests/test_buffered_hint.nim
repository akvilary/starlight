import ../src/starlight

layout BigList(items: seq[string]) {.buf: 32.}:
  Ul:
    for item in items:
      Li: item

response showList() {.html.}:
  return BigList(items = @["a", "b", "c"])

route MainRoute:
  get("/", showList)

var app = newApp()
app.mount("/", MainRoute)
