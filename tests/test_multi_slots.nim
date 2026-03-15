import ../src/starlight

# --- Layout with two lazy params ---

layout TwoLazy(headerContent: lazyLayout, bodyContent: lazyLayout) {.buf.}:
  Div(class="page"):
    headerContent
    Hr
    bodyContent

# --- Simple {.buf.} layouts to pass as lazy args ---

layout HeaderBlock() {.buf.}:
  H1: "Header content"

layout FooterBlock() {.buf.}:
  P: "Footer content"

layout Page() {.buf.}:
  TwoLazy(lazy headerContent=HeaderBlock(), lazy bodyContent=FooterBlock())

proc testMultiLazy() =
  let ctx = newContext()
  let html = Page()
  let expected = "<div class=\"page\">" &
                 "<h1>Header content</h1>" &
                 "<hr/>" &
                 "<p>Footer content</p>" &
                 "</div>"
  doAssert html == expected, "\nGot:\n" & html & "\nExpected:\n" & expected

testMultiLazy()
echo "test_multi_lazy: OK"
