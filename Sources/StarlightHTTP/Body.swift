//===----------------------------------------------------------------------===//
//
//  Body.swift
//  StarlightHTTP
//
//  HTTP message body — port of `http_body::Body` + hyper's `Recv` /
//  `Sender` aggregate.
//
//===----------------------------------------------------------------------===//

import Foundation

/// A concrete HTTP body: a single contiguous byte buffer.
///
/// This is the axum `Bytes` analogue — bodies are materialised into
/// a single buffer for the extractor pipeline. Streaming bodies
/// (hyper's `Frame<..., Data>`) will land in a later phase; for now
/// every body is fully buffered, matching axum's default for
/// `Bytes` / `Json<T>` / `Form<T>` extractors.
///
/// Storage: `[UInt8]`. COW via `Array`'s normal value semantics —
/// passing a `Body` between layers is one refcount bump, not a copy.
public struct Body: Sendable, Equatable, CustomStringConvertible {
    public var bytes: [UInt8]

    @inlinable public init() { self.bytes = [] }
    @inlinable public init(_ bytes: [UInt8]) { self.bytes = bytes }
    @inlinable public init(_ string: String) { self.bytes = Array(string.utf8) }
    @inlinable public init(_ data: Data) { self.bytes = Array(data) }

    @inlinable public var count: Int { bytes.count }
    @inlinable public var isEmpty: Bool { bytes.isEmpty }

    @inlinable public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try bytes.withUnsafeBufferPointer { try body(UnsafeRawBufferPointer($0)) }
    }

    public var description: String {
        "<Body \(count) bytes>"
    }
}
