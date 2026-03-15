import ../src/starlight

# --- Simple buffered layout (no lazy params) ---

layout SiteHeader() {.buf.}:
  Header:
    H1: "My Site"

# --- Buffered layout with lazy param ---

layout Wrapper(title: string, content: lazyLayout) {.buf.}:
  Html:
    Head:
      Title: title
    Body:
      content
      Footer: "End"

# --- Buffered layout using lazy ---

layout Page(title: string) {.buf.}:
  Wrapper(title=title, lazy content=SiteHeader())

# --- Handler ---

response home() {.html.}:
  return Page(title="Hello")

# --- Routes ---

route MainRoute:
  get("/", home)

var app = newApp()
app.mount("/", MainRoute)

# --- Verify buffer order ---

proc testBufferOrder() =
  let ctx = newContext()
  let html = Page(title="Hello")
  let expected = "<html><head><title>Hello</title></head><body>" &
                 "<header><h1>My Site</h1></header>" &
                 "<footer>End</footer>" &
                 "</body></html>"
  doAssert html == expected, "\nGot:\n" & html & "\nExpected:\n" & expected

testBufferOrder()
echo "test_buffered: OK"
