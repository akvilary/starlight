import std/unittest
import ../src/starlight

layout RawText() {.buf.}:
  P:
    raw "Hello "
    Strong: "world"

layout RawEscaped(userInput: string) {.buf.}:
  P:
    raw escapeHtml(userInput)

suite "raw keyword":
  let ctx = newContext()

  test "raw inserts string literal as-is":
    let html = RawText()
    check html == "<p>Hello <strong>world</strong></p>"

  test "raw with escapeHtml escapes content":
    let html = RawEscaped(userInput="<script>alert('xss')</script>")
    check html == "<p>&lt;script&gt;alert(&#x27;xss&#x27;)&lt;/script&gt;</p>"
