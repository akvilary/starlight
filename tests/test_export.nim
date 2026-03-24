import std/unittest
import ../src/starlight
import helpers/export_defs

layout TestPage() {.buf.}:
  ExportedGeneric(lazy content=ExportedBlock())

suite "export marker *":

  test "exported layout from another module":
    let html = ExportedLayout(title="Hello")
    check html == "<html><head><title>Hello</title></head><body>" &
                  "<p>exported</p>" &
                  "</body></html>"

  test "exported layout no params":
    let html = ExportedBlock()
    check html == "<span>block</span>"

  test "exported generic layout with lazy":
    let html = TestPage()
    check html == "<section><span>block</span></section>"

  test "layout without * is not importable":
    check not compiles(PrivateLayout(title="test"))
