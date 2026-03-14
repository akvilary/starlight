## HTML escaping utilities.

proc escapeHtml*(s: string): string {.inline.} =
  ## Escapes HTML special characters. Safe for both content and attributes.
  result = newStringOfCap(s.len)
  for c in s:
    case c
    of '&': result.add "&amp;"
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    of '"': result.add "&quot;"
    of '\'': result.add "&#x27;"
    else: result.add c
