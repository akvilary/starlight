import std/unittest
import ../src/starlight

layout SiteHeader() {.buf.}:
  Header:
    H1: "My Site"

layout Wrapper(title: string, content: lazyLayout[SiteHeader]) {.buf.}:
  Html:
    Head:
      Title: title
    Body:
      content
      Footer: "End"

layout Page(title: string) {.buf.}:
  Wrapper(title=title, lazy content=SiteHeader())

suite "buffered layouts":


  test "buffer order with lazy content":
    let html = Page(title="Hello")
    check html == "<html><head><title>Hello</title></head><body>" &
                  "<header><h1>My Site</h1></header>" &
                  "<footer>End</footer>" &
                  "</body></html>"
