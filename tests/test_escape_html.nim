import ../src/starlight

# --- Test escapeHtml as a regular function inside layouts ---

layout SafeComment(userInput: string) {.buf.}:
  P: escapeHtml(userInput)

layout SafeAttr(cls: string) {.buf.}:
  Div(class=escapeHtml(cls)):
    "content"

layout MixedContent(trusted: string, untrusted: string) {.buf.}:
  Div:
    raw trusted
    P: escapeHtml(untrusted)

proc testEscapeInTag() =
  let ctx = newContext()
  let html = SafeComment(userInput="<script>alert('xss')</script>")
  let expected = "<p>&lt;script&gt;alert(&#x27;xss&#x27;)&lt;/script&gt;</p>"
  doAssert html == expected, "\nGot:\n" & html & "\nExpected:\n" & expected

proc testEscapeInAttr() =
  let ctx = newContext()
  let html = SafeAttr(cls="foo\" onclick=\"alert(1)")
  let expected = "<div class=\"foo&quot; onclick=&quot;alert(1)\">content</div>"
  doAssert html == expected, "\nGot:\n" & html & "\nExpected:\n" & expected

proc testMixedContent() =
  let ctx = newContext()
  let html = MixedContent(trusted="<b>bold</b>", untrusted="<b>bold</b>")
  let expected = "<div><b>bold</b><p>&lt;b&gt;bold&lt;/b&gt;</p></div>"
  doAssert html == expected, "\nGot:\n" & html & "\nExpected:\n" & expected

proc testEscapeSpecialChars() =
  let ctx = newContext()
  let html = SafeComment(userInput="Tom & Jerry < Friends > Enemies \"quoted\" 'apos'")
  let expected = "<p>Tom &amp; Jerry &lt; Friends &gt; Enemies &quot;quoted&quot; &#x27;apos&#x27;</p>"
  doAssert html == expected, "\nGot:\n" & html & "\nExpected:\n" & expected

proc testNoEscapeWithoutCall() =
  let ctx = newContext()
  # Without escapeHtml, dynamic content is inserted as-is
  let input = "<b>bold</b>"
  let html = MixedContent(trusted=input, untrusted=input)
  let expected = "<div><b>bold</b><p>&lt;b&gt;bold&lt;/b&gt;</p></div>"
  doAssert html == expected, "\nGot:\n" & html & "\nExpected:\n" & expected

testEscapeInTag()
testEscapeInAttr()
testMixedContent()
testEscapeSpecialChars()
testNoEscapeWithoutCall()
echo "test_escape_html: OK"
