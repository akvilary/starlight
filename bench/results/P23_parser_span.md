# P23 — Parser adopts Span<UInt8> (SE-0447)

A/B test, 12 threads × 256 conns × 10s, endpoint `/`, 25s cooldown,
interleaved baseline/fix. (Cumulative since P22 — P23 builds on top
of P22 + P12 + P9.)

|              | run 1    | run 2    | run 3    | AVG     |
|--------------|----------|----------|----------|---------|
| baseline     | 288,988  | 286,617  | 289,419  | 288,341 |
| fix          | 325,189  | 315,499  | 327,472  | 322,720 |
| delta        |          |          |          | +11.9%  |

**Verdict**: no regression. P23 alone contributes ~+0.5% (within
noise). The real win is memory safety — the parser API now carries
the borrowing contract in its type.

## What landed

### `HTTP1Parser.feed` now takes `borrowing Span<UInt8>`

Previous signature:

    mutating func feed(_ buffer: UnsafeBufferPointer<UInt8>,
                       into ctx: inout RequestContext) throws -> Bool

New signature:

    mutating func feed(_ buffer: borrowing Span<UInt8>,
                       into ctx: inout RequestContext) throws -> Bool

`Span` is `~Copyable & ~Escapable` (SE-0447). The compiler now
guarantees that the parser:
- Cannot copy the buffer reference.
- Cannot escape it past the call (no storing in a field, no async
  capture).
- Cannot mutate it (Span is read-only; MutableSpan is the writable
  variant).

The previous `UnsafeBufferPointer` parameter carried none of these
guarantees — the name said "unsafe", and that was the only contract.

### Internal parser methods updated

`stepRequestLine`, `stepHeaders`, `decodeMethod`, `validateVersion`,
`isContentLength`, `isTransferEncoding` — all now take
`borrowing Span<UInt8>` and use `buffer[i]` subscript instead of
`buffer.baseAddress![i]`. The subscript is bounds-checked in debug
builds, zero-cost in release.

`decodeMethod` for the `.other(raw:)` fallback (unknown HTTP method)
now copies bytes via a small `[UInt8]` since `Span` cannot be passed
to `String(decoding:as:)` directly (it's `~Escapable`). For the rare
unknown-method case this is acceptable.

### `SearchAlgorithm.findByte` gained a Span overload

    public static func findByte(
        _ needle: UInt8,
        in span: borrowing Span<UInt8>,
        from start: Int,
        to end: Int
    ) -> Int?

Bridges to the canonical `UnsafePointer` implementation via
`span.withUnsafeBufferPointer` — zero allocation.

### `HeaderView.copyBlock` and `QueryView.copyBlock` gained Span overloads

Both bridge to the existing `UnsafeBufferPointer` write path via
`span.withUnsafeBufferPointer`. Zero allocation, identical behaviour
to the existing overload.

### Codec updated

`HTTP1Codec.parseAndExtract` now constructs a `Span` from the
accumulator's readable bytes and passes it to `parser.feed`:

    let span = Span(_unsafeStart: base, count: typedBytes.count)
    complete = try self.parser.feed(span, into: &self.ctx)

## What's NOT changed

- `ctx.path` and `ctx.body` are still `ByteBuffer` (#24 — bigger
  refactor, would require either making RequestContext `~Escapable`
  or introducing a separate PathView type).
- `codec.feed(UnsafeBufferPointer<UInt8>)` overload for the io_uring /
  epoll backends — internal use, callers still pass raw pointers.
- `HeaderView` / `QueryView` subscript APIs — they walk their own
  ByteBuffer internally, not a caller-supplied Span.

Tests: 119/119 passed.
