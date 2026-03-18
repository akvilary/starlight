import std/unittest
import ../src/starlight

layout SafeComment(userInput: string) {.buf.}:
  P: escapeHtml(userInput)

layout SafeAttr(cls: string) {.buf.}:
  Div(class=escapeHtml(cls)):
    "content"

layout MixedContent(trusted: string, untrusted: string) {.buf.}:
  Div:
    raw trusted
    P: escapeHtml(untrusted)

suite "escapeHtml in layouts":


  test "escapes tag content":
    let html = SafeComment(userInput="<script>alert('xss')</script>")
    check html == "<p>&lt;script&gt;alert(&#x27;xss&#x27;)&lt;/script&gt;</p>"

  test "escapes attribute value":
    let html = SafeAttr(cls="foo\" onclick=\"alert(1)")
    check html == "<div class=\"foo&quot; onclick=&quot;alert(1)\">content</div>"

  test "mixed raw and escaped content":
    let html = MixedContent(trusted="<b>bold</b>", untrusted="<b>bold</b>")
    check html == "<div><b>bold</b><p>&lt;b&gt;bold&lt;/b&gt;</p></div>"

  test "escapes all special characters":
    let html = SafeComment(userInput="Tom & Jerry < Friends > Enemies \"quoted\" 'apos'")
    check html == "<p>Tom &amp; Jerry &lt; Friends &gt; Enemies &quot;quoted&quot; &#x27;apos&#x27;</p>"
