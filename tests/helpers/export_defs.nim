import ../../src/starlight

layout ExportedLayout*(title: string) {.buf.}:
  Html:
    Head:
      Title: title
    Body:
      P: "exported"

layout PrivateLayout(title: string) {.buf.}:
  Div: title

layout ExportedBlock*() {.buf.}:
  Span: "block"

layout ExportedGeneric*[T](content: lazyLayout[T]) {.buf.}:
  Section:
    content

handler exportedHandler*(ctx: Context) {.html.}:
  return ExportedLayout(title="test")

middleware exportedMiddleware*(ctx: Context, next: HandlerProc):
  return await next(ctx)
