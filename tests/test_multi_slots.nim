import ../src/starlight

# --- Layout with two named slots ---

layout TwoSlots() {.toBuffer.}:
  Div(class="page"):
    <-S1
    Hr
    <-S2

layout Page() {.toBuffer.}:
  inject TwoSlots():
    ->S1:
      H1: "Header content"
    ->S2:
      P: "Footer content"

proc testMultiSlots() =
  let ctx = newContext()
  let html = Page()
  let expected = "<div class=\"page\">" &
                 "<h1>Header content</h1>" &
                 "<hr/>" &
                 "<p>Footer content</p>" &
                 "</div>"
  doAssert html == expected, "\nGot:\n" & html & "\nExpected:\n" & expected

testMultiSlots()
echo "test_multi_slots: OK"
