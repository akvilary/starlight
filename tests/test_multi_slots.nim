import std/unittest
import ../src/starlight

layout TwoLazy(headerContent: lazyLayout, bodyContent: lazyLayout) {.buf.}:
  Div(class="page"):
    headerContent
    Hr
    bodyContent

layout HeaderBlock() {.buf.}:
  H1: "Header content"

layout FooterBlock() {.buf.}:
  P: "Footer content"

layout Page() {.buf.}:
  TwoLazy(lazy headerContent=HeaderBlock(), lazy bodyContent=FooterBlock())

suite "multiple lazy parameters":


  test "two lazy params rendered in correct order":
    let html = Page()
    check html == "<div class=\"page\">" &
                  "<h1>Header content</h1>" &
                  "<hr/>" &
                  "<p>Footer content</p>" &
                  "</div>"
