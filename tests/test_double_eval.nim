import std/unittest
import ../src/starlight

var callCount = 0

proc sideEffect(): string =
  inc callCount
  "called"

layout Inner(value: string) {.buf.}:
  Span: value

layout Outer(content: lazyLayout[Inner]) {.buf.}:
  Div:
    content

layout Page() {.buf.}:
  Outer(lazy content=Inner(value=sideEffect()))

suite "double evaluation":


  test "side effect called exactly once in nested lazy":
    callCount = 0
    let html = Page()
    check html == "<div><span>called</span></div>"
    check callCount == 1
