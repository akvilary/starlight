import ../src/starlight

# --- Test that dynamic expressions are not evaluated twice ---

var callCount = 0

proc sideEffect(): string =
  inc callCount
  "called"

layout Inner(value: string) {.buf.}:
  Span: value

layout Outer(content: lazyLayout) {.buf.}:
  Div:
    content

layout Page() {.buf.}:
  Outer(lazy content=Inner(value=sideEffect()))

proc testDoubleEval() =
  callCount = 0
  let ctx = newContext()
  let html = Page()
  let expected = "<div><span>called</span></div>"
  doAssert html == expected, "\nGot:\n" & html & "\nExpected:\n" & expected
  doAssert callCount == 1, "sideEffect() called " & $callCount & " times, expected 1"

testDoubleEval()
echo "test_double_eval: OK"
