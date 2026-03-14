## Compile-time sets of HTML tag names.

import std/[sets, tables]

const htmlTags* = toHashSet([
  "html", "head", "body", "title", "meta", "link", "style", "script",
  "div", "span", "p", "a", "img", "br", "hr",
  "h1", "h2", "h3", "h4", "h5", "h6",
  "ul", "ol", "li", "dl", "dt", "dd",
  "table", "thead", "tbody", "tfoot", "tr", "th", "td", "caption", "colgroup", "col",
  "form", "input", "button", "select", "option", "optgroup", "textarea", "label",
  "fieldset", "legend",
  "header", "footer", "nav", "main", "section", "article", "aside",
  "figure", "figcaption", "details", "summary",
  "pre", "code", "blockquote", "cite",
  "strong", "em", "b", "i", "u", "s", "small", "sub", "sup", "mark",
  "abbr", "time", "progress", "meter",
  "audio", "video", "source", "canvas", "svg",
  "iframe", "embed", "object", "param",
  "noscript", "slot",
  "dialog", "data", "output", "picture", "map", "area",
  "del", "ins", "dfn", "kbd", "samp", "wbr", "bdi", "bdo", "ruby", "rt", "rp",
])

const voidTags* = toHashSet([
  "area", "base", "br", "col", "embed", "hr", "img", "input",
  "link", "meta", "param", "source", "track", "wbr",
])

const tagAliases* = {
  "tdiv": "div",
  "ttemplate": "template",
  "tobject": "object",
  "tvar": "var",
}.toTable
