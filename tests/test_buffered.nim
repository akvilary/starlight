import ../src/starlight

# --- Simple buffered layout (no slots) ---

layout SiteHeader() {.toBuffer.}:
  Header:
    H1: "My Site"

# --- Buffered layout with container slot ---

layout Wrapper(title: string) {.toBuffer.}:
  Html:
    Head:
      Title: title
    Body:
      container
      Footer: "End"

# --- Buffered layout using containered ---

layout Page(title: string) {.toBuffer.}:
  containered Wrapper(title=title):
    SiteHeader()
    Main:
      H1: "Welcome"

# --- Handler using buffered layout ---

responseHtml home():
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
                 "<main><h1>Welcome</h1></main>" &
                 "<footer>End</footer>" &
                 "</body></html>"
  doAssert html == expected, "\nGot:\n" & html & "\nExpected:\n" & expected

testBufferOrder()
echo "test_buffered: OK"
