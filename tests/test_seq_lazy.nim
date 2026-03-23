import std/unittest
import ../src/starlight

layout ItemBlock(title: string) {.buf.}:
  Li: title

layout ItemList(items: openarray[lazyLayout[ItemBlock]]) {.buf.}:
  Ul:
    items

layout WrappedList(items: openarray[lazyLayout[ItemBlock]]) {.buf.}:
  Ul:
    for item in items:
      Div(class="wrapper"):
        item

layout EmptyContainer(items: openarray[lazyLayout[ItemBlock]]) {.buf.}:
  Div:
    items

layout PageAutoIterate() {.buf.}:
  ItemList(lazy items=[ItemBlock(title="A"), ItemBlock(title="B")])

layout PageForLoop() {.buf.}:
  WrappedList(lazy items=[ItemBlock(title="X"), ItemBlock(title="Y")])

layout PageEmpty() {.buf.}:
  EmptyContainer()

layout PageSingle() {.buf.}:
  ItemList(lazy items=[ItemBlock(title="Only")])

suite "openarray[lazyLayout[X]]":


  test "auto-iteration with bare ident":
    let html = PageAutoIterate()
    check html == "<ul><li>A</li><li>B</li></ul>"

  test "for-loop iteration with wrapping":
    let html = PageForLoop()
    check html == "<ul>" &
                  "<div class=\"wrapper\"><li>X</li></div>" &
                  "<div class=\"wrapper\"><li>Y</li></div>" &
                  "</ul>"

  test "empty openarray renders nothing":
    let html = PageEmpty()
    check html == "<div></div>"

  test "single-element openarray":
    let html = PageSingle()
    check html == "<ul><li>Only</li></ul>"
