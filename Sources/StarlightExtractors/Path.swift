//===----------------------------------------------------------------------===//
//
//  Path.swift
//  StarlightExtractors
//
//  Direct port of `axum::extract::Path<T>`.
//
//===----------------------------------------------------------------------===//

import Foundation
import StarlightCore
import HTTP

/// Extractor for URL path parameters captured by the route pattern.
///
/// `Path<T>` decodes the matched parameters into `T` via
/// `Decodable`. Example:
///
/// ```swift
/// struct UserId: Decodable {
///     let id: Int
/// }
/// router.get("/users/:id") { (_: Path<UserId>) in
///     return .plain("ok")
/// }
/// ```
public struct Path<T: Decodable & Sendable>: Sendable {
    public let value: T

    @inlinable public init(_ value: T) { self.value = value }
}

extension Path: FromRequestParts {
    public typealias State = AnySendable

    public static func fromRequestParts(
        _ parts: inout RequestParts,
        state: borrowing AnySendable
    ) async throws -> Path<T> {
        guard let matched = parts.extensions.get(MatchedPathParams.self) else {
            throw ExtractionRejection("missing matched path params", status: .internalServerError)
        }
        do {
            let decoded = try matched.params.decode(T.self)
            return Path(decoded)
        } catch {
            throw ExtractionRejection("path decode failed: \(error)", status: .badRequest)
        }
    }
}
