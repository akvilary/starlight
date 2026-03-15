import ../src/starlight

# --- Depth 2: inner layout with S1 slot ---

layout Inner() {.buf.}:
  Div(class="inner"):
    <-S1

# --- Depth 1: outer layout with S1 slot ---

layout Outer() {.buf.}:
  Div(class="outer"):
    <-S1

# --- Page: depth 0, injects into Outer which injects into Inner ---

layout Page() {.buf.}:
  inject Outer():
    ->S1:
      H1: "Outer content"
      inject Inner():
        ->S1:
          P: "Inner content"

proc testNestedInject() =
  let ctx = newContext()
  let html = Page()
  let expected =
    "<div class=\"outer\">" &
      "<h1>Outer content</h1>" &
      "<div class=\"inner\">" &
        "<p>Inner content</p>" &
      "</div>" &
    "</div>"
  doAssert html == expected, "\nGot:\n" & html & "\nExpected:\n" & expected

testNestedInject()
echo "test_nested_inject: OK"
