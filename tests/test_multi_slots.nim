import ../src/starlight

# --- Layout with two named inject blocks ---

layout TwoBlocks() {.buf.}:
  Div(class="page"):
    <-S1
    Hr
    <-S2

layout Page() {.buf.}:
  inject TwoBlocks():
    ->S1:
      H1: "Header content"
    ->S2:
      P: "Footer content"

proc testMultiInjectBlocks() =
  let ctx = newContext()
  let html = Page()
  let expected = "<div class=\"page\">" &
                 "<h1>Header content</h1>" &
                 "<hr/>" &
                 "<p>Footer content</p>" &
                 "</div>"
  doAssert html == expected, "\nGot:\n" & html & "\nExpected:\n" & expected

testMultiInjectBlocks()
echo "test_multi_inject_blocks: OK"
