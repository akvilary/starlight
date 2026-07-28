//===----------------------------------------------------------------------===//
//
//  RawRequest.swift
//  StarlightExtractors
//
//  Direct port of `axum::extract::Request` — the whole request as
//  an extractor.
//
//  Useful when you need access to the raw request (method, path,
//  headers, body) without committing to specific extractors.
//
//===----------------------------------------------------------------------===//

import Foundation
import HTTP
import StarlightCore

/// Extractor that yields the whole request.
///
/// Direct port of `axum::extract::Request`. Consumes the request
/// entirely — must be the LAST positional extractor in a handler
/// (since it takes ownership of the body).
///
/// ```swift
/// router.post("/echo") { (req: RawRequest) in
///     return .plain("got \(req.method) \(req.uri.pathString)")
/// }
/// ```
public typealias RawRequest = Request

extension Request: FromRequest {

    public static func fromRequest<S: Sendable>(
        _ request: consuming Request,
        state: borrowing S
    ) async throws -> Request {
        request
    }
}
