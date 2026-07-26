//===----------------------------------------------------------------------===//
//
//  Json.swift
//  StarlightExtractors
//
//  Direct port of `axum::extract::Json<T>`.
//
//===----------------------------------------------------------------------===//

import Foundation
import StarlightCore
import HTTP
import StarlightTower

/// Extractor for a JSON request body, plus a response wrapper.
///
/// As an extractor: consumes the request body and decodes it as
/// JSON via `JSONDecoder`.
///
/// As a response: encodes the wrapped value with `JSONEncoder` and
/// sets `Content-Type: application/json`.
public struct Json<T: Sendable>: Sendable {
    public let value: T

    @inlinable public init(_ value: T) { self.value = value }
}

extension Json: FromRequest where T: Decodable {
    public typealias State = AnySendable

    public static func fromRequest(
        _ request: consuming Request,
        state: borrowing AnySendable
    ) async throws -> Json<T> {
        // B2 FIX: Content-Type check BEFORE decode.
        // Missing/wrong Content-Type → 415 Unsupported Media Type.
        // Decode failure → 400 Bad Request.
        let ct = request.headers.first(for: .contentType)?.description ?? ""
        if !ct.lowercased().hasPrefix("application/json") {
            throw ExtractionRejection(
                "expected application/json, got \(ct.isEmpty ? "missing" : ct)",
                status: .unsupportedMediaType  // 415
            )
        }
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
        do {
            let decoded = try JSONDecoder().decode(T.self, from: Data(bytes))
            return Json(decoded)
        } catch {
            throw ExtractionRejection(
                "json decode failed: \(error)",
                status: .badRequest  // 400 — NOT 415
            )
        }
    }
}

extension Json: IntoResponse where T: Encodable {
    public func intoResponse() -> Response {
        do {
            let data = try JSONEncoder().encode(value)
            var headers = HeaderMap()
            headers.insert(.contentType, "application/json; charset=utf-8")
            headers.insert(.contentLength, String(data.count))
            return Response(
                status: .ok, headers: headers, body: .buffered(Array(data))
            )
        } catch {
            return .plain("json encode failed: \(error)", status: .internalServerError)
        }
    }
}
