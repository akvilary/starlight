import ../src/starlight

# --- Inner layout with lazy param ---

layout Inner(content: lazyLayout) {.buf.}:
  Div(class="inner"):
    content

# --- Outer layout with lazy param, forwards to Inner ---

layout Outer(content: lazyLayout) {.buf.}:
  Div(class="outer"):
    Inner(lazy content=content)   # forward lazy param

# --- Page ---

layout ContentBlock() {.buf.}:
  P: "Inner content"

layout Page() {.buf.}:
  Outer(lazy content=ContentBlock())

proc testNestedLazy() =
  let ctx = newContext()
  let html = Page()
  let expected =
    "<div class=\"outer\">" &
      "<div class=\"inner\">" &
        "<p>Inner content</p>" &
      "</div>" &
    "</div>"
  doAssert html == expected, "\nGot:\n" & html & "\nExpected:\n" & expected

testNestedLazy()
echo "test_nested_lazy: OK"
