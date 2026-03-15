import ../src/starlight

# --- Simple buffered layout (no slots) ---

layout Header() {.toBuffer.}:
  header:
    h1: "My Site"

# --- Buffered layout with container slot ---

layout Wrapper(title: string) {.toBuffer.}:
  html:
    head:
      title: title
    body:
      container
      footer: "End"

# --- Buffered layout using containered ---

layout Page(title: string) {.toBuffer.}:
  containered Wrapper(title=title):
    Header()
    main:
      h1: "Welcome"

# --- Handler using buffered layout ---

responseHtml home():
  return Page(title="Hello")

# --- Routes ---

route Main:
  get("/", home)

var app = newApp()
app.mount("/", Main)

# --- Verify buffer order ---

proc testBufferOrder() =
  let ctx = newContext()
  let html = Page(title="Hello")
  let expected = "<html><head><title>Hello</title></head><body>" &
                 "<header><h1>My Site</h1></header>" &
                 "<main><h1>Welcome</h1></main>" &
                 "<footer>End</footer>" &
                 "</body></html>"
  doAssert html == expected, "\nGot:\n" & html & "\nExpected:\n" & expected

testBufferOrder()
echo "test_buffered: OK"
