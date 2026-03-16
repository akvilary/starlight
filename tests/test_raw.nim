import ../src/starlight

layout RawText() {.buf.}:
  P:
    raw "Hello "
    Strong: "world"

layout RawEscaped(userInput: string) {.buf.}:
  P:
    raw escapeHtml(userInput)

proc testRawText() =
  let ctx = newContext()
  let html = RawText()
  let expected = "<p>Hello <strong>world</strong></p>"
  doAssert html == expected, "\nGot:\n" & html & "\nExpected:\n" & expected

proc testRawEscaped() =
  let ctx = newContext()
  let html = RawEscaped(userInput="<script>alert('xss')</script>")
  let expected = "<p>&lt;script&gt;alert(&#x27;xss&#x27;)&lt;/script&gt;</p>"
  doAssert html == expected, "\nGot:\n" & html & "\nExpected:\n" & expected

testRawText()
testRawEscaped()
echo "test_raw: OK"
