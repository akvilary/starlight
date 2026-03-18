import std/unittest
import ../src/starlight

layout Inner(content: lazyLayout) {.buf.}:
  Div(class="inner"):
    content

layout Outer(content: lazyLayout) {.buf.}:
  Div(class="outer"):
    Inner(lazy content=content)

layout ContentBlock() {.buf.}:
  P: "Inner content"

layout Page() {.buf.}:
  Outer(lazy content=ContentBlock())

suite "nested lazy forwarding":


  test "lazy param forwarded through nested layouts":
    let html = Page()
    check html == "<div class=\"outer\">" &
                    "<div class=\"inner\">" &
                      "<p>Inner content</p>" &
                    "</div>" &
                  "</div>"
