//===----------------------------------------------------------------------===//
//
//  Uri.swift
//  StarlightHTTP
//
//  Request target URI. Port of `http::Uri`.
//
//===----------------------------------------------------------------------===//

import Foundation

/// Request target — the part after the method on the request line:
///
///     GET /users/42?active=true HTTP/1.1
///             ^^^^^^^^^^^^^^^^^^
///
/// Stored as a heap-stable `Substring` view of the request buffer;
/// path / query / fragments are exposed via computed properties that
/// lazily slice into the same backing storage (no allocation until
/// the handler actually reads them).
public struct Uri: Sendable, Hashable, CustomStringConvertible {
    /// Raw bytes of the request target, as received on the wire
    /// (already percent-encoded).
    public let bytes: [UInt8]

    @inlinable
    public init(_ raw: String) {
        self.bytes = Array(raw.utf8)
    }

    @inlinable
    public init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// Path portion — everything up to `?` or `#`, no query/fragment.
    ///
    /// Returned as raw bytes so the router's byte-wise matcher can
    /// compare against pre-compiled literal segments without
    /// allocating a `String`. Materialise via `pathString` if needed.
    @inlinable
    public var pathBytes: ArraySlice<UInt8> {
        let end = bytes.firstIndex(of: 0x3F)  // '?'
            ?? bytes.firstIndex(of: 0x23)     // '#'
            ?? bytes.endIndex
        return bytes[..<end]
    }

    @inlinable
    public var pathString: String {
        String(decoding: pathBytes, as: UTF8.self)
    }

    /// Query string — bytes after `?`, up to `#` or end. `nil` if
    /// no `?` was present.
    @inlinable
    public var queryBytes: ArraySlice<UInt8>? {
        guard let q = bytes.firstIndex(of: 0x3F) else { return nil }  // '?'
        let start = q + 1
        let end = bytes[start...].firstIndex(of: 0x23) ?? bytes.endIndex  // '#'
        return bytes[start..<end]
    }

    @inlinable
    public var queryString: String? {
        queryBytes.map { String(decoding: $0, as: UTF8.self) }
    }

    public var description: String {
        String(decoding: bytes, as: UTF8.self)
    }
}
