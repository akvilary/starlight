## Compile-time sets of HTML tag names (TitleCase).
## DSL uses TitleCase (Div, H1, P), output is lowercase (<div>, <h1>, <p>).

import std/[sets, strutils]

const htmlTags* = toHashSet([
  "Html", "Head", "Body", "Title", "Meta", "Link", "Style", "Script",
  "Div", "Span", "P", "A", "Img", "Br", "Hr",
  "H1", "H2", "H3", "H4", "H5", "H6",
  "Ul", "Ol", "Li", "Dl", "Dt", "Dd",
  "Table", "Thead", "Tbody", "Tfoot", "Tr", "Th", "Td", "Caption", "Colgroup", "Col",
  "Form", "Input", "Button", "Select", "Option", "Optgroup", "Textarea", "Label",
  "Fieldset", "Legend",
  "Header", "Footer", "Nav", "Main", "Section", "Article", "Aside",
  "Figure", "Figcaption", "Details", "Summary",
  "Pre", "Code", "Blockquote", "Cite",
  "Strong", "Em", "B", "I", "U", "S", "Small", "Sub", "Sup", "Mark",
  "Abbr", "Time", "Progress", "Meter",
  "Audio", "Video", "Source", "Canvas", "Svg",
  "Iframe", "Embed", "Object", "Param",
  "Noscript", "Slot",
  "Dialog", "Data", "Output", "Picture", "Map", "Area",
  "Del", "Ins", "Dfn", "Kbd", "Samp", "Wbr", "Bdi", "Bdo", "Ruby", "Rt", "Rp",
  "Template", "Var",
])

const voidTags* = toHashSet([
  "Area", "Base", "Br", "Col", "Embed", "Hr", "Img", "Input",
  "Link", "Meta", "Param", "Source", "Track", "Wbr",
])

proc tagToHtml*(name: string): string =
  ## Convert TitleCase tag name to lowercase HTML tag.
  name.toLowerAscii
