import std/unittest
import ../src/starlight

layout BigList(items: seq[string]) {.buf: 32.}:
  Ul:
    for item in items:
      Li: item

suite "buffered layout with capacity hint":


  test "renders list with {.buf: 32.} hint":
    let html = BigList(items = @["a", "b", "c"])
    check html == "<ul><li>a</li><li>b</li><li>c</li></ul>"
