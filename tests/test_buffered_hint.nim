import ../src/starlight

layout BigList(items: seq[string]) {.toBuffer: 32.}:
  ul:
    for item in items:
      li: item

responseHtml showList():
  return BigList(items = @["a", "b", "c"])

route Main:
  get("/", showList)

var app = newApp()
app.mount("/", Main)
