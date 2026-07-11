//===----------------------------------------------------------------------===//
//
//  RequestContext.swift
//  StarlightHTTP
//
//  Per-request state, modelled on fasthttp's `RequestCtx` but with the
//  reuse-invariant enforced at compile time by Swift's ownership model.
//
//  ─── Why `~Copyable` ───────────────────────────────────────────────────
//
//  fasthttp reuses a single `RequestCtx` per connection across all
//  keep-alive requests and warns the user "do not retain `RequestCtx`
//  references after the handler returns" — a runtime hazard that Go's
//  type system cannot enforce. Swift's `~Copyable` lets us encode the
//  same invariant statically:
//
//    - The context is owned by exactly one task (the connection's task).
//    - It is passed to handlers as `borrowing RequestContext` — the
//      handler cannot escape it, cannot store it, cannot keep it alive
//      past its scope.
//    - Between requests the owner calls `reset()`, which bulk-clears
//      the parsed fields in one O(1) pass.
//
//===----------------------------------------------------------------------===//

import NIOCore

/// Per-request state owned by a single connection's task.
///
/// One instance per connection, reused across all keep-alive requests.
/// The owner resets the context between requests via `reset()`.
///
/// Handlers receive the context as `borrowing RequestContext` — they
/// cannot copy it, store it, or extend its lifetime past the handler
/// call. This is the compile-time-enforced equivalent of fasthttp's
/// runtime-only "don't keep references" invariant.
public struct RequestContext: ~Copyable {
    /// HTTP method. Populated by the SIMD parser.
    public var method: HTTPMethod

    /// HTTP status code that the handler will emit. Defaults to 200 OK;
    /// handlers can mutate it (e.g., set to 404 for not-found). The
    /// response writer reads this when serializing the status line.
    public var status: HTTPStatus

    /// Request path (e.g. `/users/42`). Stored as a COW `ByteBuffer`
    /// slice of the connection's receive accumulator — zero-copy.
    /// Use `pathString` to get a `String` when needed (rare — most
    /// handlers use `params` for dynamic segments).
    public var path: ByteBuffer

    /// Path parameters extracted by the router from dynamic segments
    /// (e.g. `:id` in `/users/:id` → `params["id"] == "42"`).
    ///
    /// Backed by `Params` (array of `(name, value)` tuples) rather
    /// than a `Dictionary` — for typical 0–2-param routes this is
    /// cheaper to allocate and faster to look up.
    public var params: Params

    /// Captured request headers. Populated by the HTTP/1 parser after
    /// the entire header block has been parsed. Backed by a reusable
    /// `ByteBuffer` — zero per-request allocation after the first
    /// request on a keep-alive connection.
    public var headers: HeaderView

    /// Request body bytes (for POST/PUT/PATCH). Stored as a COW
    /// `ByteBuffer` slice of the connection's receive accumulator —
    /// zero-copy until the handler actually reads/modifies the body.
    /// Nil for bodyless requests (GET/HEAD/etc.).
    public var body: ByteBuffer?

    /// Reusable response buffer. Cleared and refilled per request by
    /// `HTTPResponse.plaintext(_:into:)` or any response builder that
    /// accepts an `inout ByteBuffer`. `ByteBuffer` is COW, so the
    /// returned `HTTPResponse` shares storage until the next write
    /// triggers copy-on-write — no memcpy on the hot path.
    ///
    /// Used internally by the codec (400/413/500 responses) and the
    /// router (404 responses). Handlers receive the context as
    /// `borrowing` and cannot pass this as `inout` — for zero-alloc
    /// responses in handlers, pre-build response buffers at startup
    /// (as the benchmark does).
    public var responseBuffer: ByteBuffer

    /// Construct an empty context.
    public init() {
        self.method = .other
        self.status = .ok
        self.path = ByteBufferAllocator().buffer(capacity: 0)
        self.params = Params()
        self.headers = HeaderView()
        self.body = nil
        self.responseBuffer = ByteBufferAllocator().buffer(capacity: 512)
    }

    /// Reset the context between keep-alive requests on the same connection.
    ///
    /// Restores `method`, `status`, `path`, `params`, `headers`, `body`
    /// to their defaults. ByteBuffer storage is retained (COW) so the
    /// next request reuses it without allocation.
    ///
    /// - Complexity: O(params.count + headers.count). Independent of
    ///   request size.
    public mutating func reset() {
        self.method = .other
        self.status = .ok
        self.path.clear()
        self.params.removeAll()
        self.headers.removeAll()
        self.body = nil
        // Note: responseBuffer is intentionally NOT cleared here.
        // It is cleared by HTTPResponse.plaintext(_:into:) when the
        // next response is written. If no response writes into it,
        // stale data is harmless because the handler always produces
        // a fresh HTTPResponse.
    }

    /// Decode the path to a `String` on demand. Allocates a heap
    /// `String` for paths > 15 bytes — use sparingly (the router
    /// matches against raw bytes, so most handlers never need this).
    @inlinable
    public var pathString: String {
        guard let s = self.path.getString(at: 0, length: self.path.readableBytes) else {
            return ""
        }
        return s
    }

    /// Convenience setter for tests and manual construction.
    /// Copies the string into the path buffer.
    public mutating func setPath(_ s: String) {
        self.path = ByteBufferAllocator().buffer(capacity: s.utf8.count)
        self.path.writeString(s)
    }
}
