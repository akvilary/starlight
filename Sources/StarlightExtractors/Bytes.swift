//===----------------------------------------------------------------------===//
//
//  Bytes.swift
//  StarlightExtractors
//
//  Direct port of `axum::extract::Bytes` (which is `bytes::Bytes`
//  re-exported with a FromRequest impl).
//
//  Drains the request body into a single buffer. The body-consuming
//  equivalent of axum's `Bytes` extractor.
//
//===----------------------------------------------------------------------===//

import Foundation
import HTTP
import StarlightCore

/// Extractor that drains the request body into a `[UInt8]`.
///
/// Direct port of `axum::extract::Bytes`. For bodyless requests
/// (GET/HEAD without Content-Length) returns an empty array.
///
/// ```swift
/// router.post("/echo") { (bytes: Bytes) in
///     return .bytes(bytes.value)  // echo back the bytes
/// }
/// ```
public struct Bytes: Sendable {
    /// The drained body bytes.
    public let value: [UInt8]

    @inlinable public init(_ value: [UInt8]) { self.value = value }
}

extension Bytes: FromRequest {

    public static func fromRequest<S: Sendable>(
        _ request: consuming Request,
        state: borrowing S
    ) async throws -> Bytes {
        let limit = DefaultBodyLimit.read(from: request.extensions)
        let bytes: [UInt8]
        do {
            bytes = try await request.body.collect(maxBytes: limit)
        } catch BodyError.limitExceeded {
            throw ExtractionRejection(
                "request body exceeds limit of \(limit) bytes",
                status: .payloadTooLarge
            )
        }
        return Bytes(bytes)
    }
}

extension Bytes: IntoResponse {
    public func intoResponse() -> Response {
        var headers = HeaderMap()
        headers.insert(.contentLength, String(value.count))
        return Response(status: .ok, headers: headers, body: .buffered(value))
    }
}
