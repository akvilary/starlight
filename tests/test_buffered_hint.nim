import ../src/starlight

layout BigList(items: seq[string]) {.toBuffer: 32.}:
  Ul:
    for item in items:
      Li: item

responseHtml showList():
  return BigList(items = @["a", "b", "c"])

route MainRoute:
  get("/", showList)

var app = newApp()
app.mount("/", MainRoute)
