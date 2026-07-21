//===----------------------------------------------------------------------===//
//
//  Sse.swift
//  StarlightCore
//
//  Direct port of `axum::response::sse::{Event, Sse}`.
//
//  Server-Sent Events response type. Wraps an AsyncSequence of Events
//  and formats them as SSE wire format (text/event-stream).
//
//===----------------------------------------------------------------------===//

import Foundation
import HTTP

/// A single Server-Sent Event.
///
/// Direct port of `axum::response::sse::Event`. Built via chained
/// builder methods:
///
/// ```swift
/// let event = SseEvent()
///     .data("{\"user\":42}")
///     .event("user_created")
///     .id("42")
/// ```
public struct SseEvent: Sendable, Hashable {
    public var data: String?
    public var event: String?   // event type
    public var id: String?      // last event ID
    public var retry: Int?      // reconnection time in ms
    public var comment: String?

    public init() {}

    // MARK: - Builders (chainable, match axum::response::sse::Event)

    public func data(_ d: String) -> SseEvent { var e = self; e.data = d; return e }
    public func event(_ e: String) -> SseEvent { var c = self; c.event = e; return c }
    public func id(_ i: String) -> SseEvent { var e = self; e.id = i; return e }
    public func retry(_ ms: Int) -> SseEvent { var e = self; e.retry = ms; return e }
    public func comment(_ c: String) -> SseEvent { var e = self; e.comment = c; return e }

    /// Format as SSE wire bytes. Matches the format defined in the
    /// [SSE spec](https://html.spec.whatwg.org/multipage/server-sent-events.html).
    ///
    /// Each field on its own line; multi-line `data` gets split into
    /// multiple `data:` lines. Terminated by `\n\n`.
    public func toBytes() -> [UInt8] {
        var lines: [String] = []
        if let comment { lines.append(":\(comment)") }
        if let event { lines.append("event:\(event)") }
        if let id { lines.append("id:\(id)") }
        if let retry { lines.append("retry:\(retry)") }
        if let data {
            // Multi-line data: each line gets its own `data:` prefix.
            for line in data.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append("data:\(line)")
            }
        }
        // Join with \n, terminate with \n\n.
        return Array((lines.joined(separator: "\n") + "\n\n").utf8)
    }
}

/// A Server-Sent Events response.
///
/// Direct port of `axum::response::sse::Sse<S>`. Wraps an
/// `AsyncSequence` of `SseEvent`s and formats the response as
/// `text/event-stream`.
///
/// ```swift
/// router.get("/events") {
///     Sse(SSESource())  // AsyncSequence<SseEvent>
/// }
/// ```
public struct Sse<S: AsyncSequence<SseEvent, Error> & Sendable>: Sendable {
    public let stream: S

    @inlinable public init(_ stream: S) {
        self.stream = stream
    }
}

extension Sse: IntoResponse {
    public func intoResponse() -> Response<Body> {
        // Convert AsyncSequence<SseEvent> → AsyncSequence<[UInt8]>
        // by formatting each event to SSE wire bytes.
        let byteStream = AsyncThrowingMapSequence(base: stream)
        var headers = HeaderMap()
        headers.insert(.contentType, "text/event-stream")
        headers.insert(.cacheControl, "no-cache")
        headers.insert(.connection, "keep-alive")
        return Response<Body>(
            status: .ok,
            headers: headers,
            body: .stream(byteStream)
        )
    }
}

/// Wrapper that maps `AsyncSequence<SseEvent>` → `AsyncSequence<[UInt8]>`.
struct AsyncThrowingMapSequence<S: AsyncSequence>: @unchecked Sendable
where S.Element == SseEvent, S.Failure == Error {
    let base: S
    init(base: S) { self.base = base }
}

extension AsyncThrowingMapSequence: AsyncSequence {
    typealias Element = [UInt8]
    typealias Failure = Error

    func makeAsyncIterator() -> Iterator {
        Iterator(base: base.makeAsyncIterator())
    }

    struct Iterator: AsyncIteratorProtocol, @unchecked Sendable {
        var base: S.AsyncIterator

        mutating func next() async throws -> [UInt8]? {
            guard let event = try await base.next() else { return nil }
            return event.toBytes()
        }
    }
}

// MARK: - Cache-Control header name

extension HeaderName {
    /// `Cache-Control`
    public static let cacheControl = HeaderName("cache-control")
}
