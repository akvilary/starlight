import std/unittest
import ../src/starlight

layout BlockA() {.buf.}:
  Div(class="a"): "Content A"

layout BlockB() {.buf.}:
  Div(class="b"): "Content B"

layout GenericShell[T](title: string, content: lazyLayout[T]) {.buf.}:
  Html:
    Head:
      Title: title
    Body:
      content

layout PageA() {.buf.}:
  GenericShell(title="Page A", lazy content=BlockA())

layout PageB() {.buf.}:
  GenericShell(title="Page B", lazy content=BlockB())

layout GenericForward[T](content: lazyLayout[T]) {.buf.}:
  Div(class="wrapper"):
    content

layout NestedGeneric[T](content: lazyLayout[T]) {.buf.}:
  Section:
    GenericForward(lazy content=content)

layout DeepPage() {.buf.}:
  NestedGeneric(lazy content=BlockA())

layout Shell[T, Y](header: lazyLayout[T], content: lazyLayout[Y]) {.buf.}:
  Html:
    Body:
      Header:
        header
      Main:
        content

layout ShellPage() {.buf.}:
  Shell(lazy header=BlockA(), lazy content=BlockB())

suite "generic lazyLayout[T]":

  test "generic layout accepts different concrete types":
    let htmlA = PageA()
    check htmlA == "<html><head><title>Page A</title></head><body>" &
                   "<div class=\"a\">Content A</div>" &
                   "</body></html>"
    let htmlB = PageB()
    check htmlB == "<html><head><title>Page B</title></head><body>" &
                   "<div class=\"b\">Content B</div>" &
                   "</body></html>"

  test "multiple generic params [T, Y]":
    let html = ShellPage()
    check html == "<html><body>" &
                    "<header><div class=\"a\">Content A</div></header>" &
                    "<main><div class=\"b\">Content B</div></main>" &
                  "</body></html>"

  test "generic lazy param forwarded through nested layouts":
    let html = DeepPage()
    check html == "<section>" &
                    "<div class=\"wrapper\">" &
                      "<div class=\"a\">Content A</div>" &
                    "</div>" &
                  "</section>"
