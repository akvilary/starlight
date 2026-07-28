//===----------------------------------------------------------------------===//
//
//  Host.swift
//  StarlightCore
//
//  Direct port of `axum::extract::Host`.
//
//  Extracts the Host header (or X-Forwarded-Host / Forwarded) as a
//  typed `Host` struct.
//
//===----------------------------------------------------------------------===//

import Foundation
import HTTP

/// Extractor for the request's Host.
///
/// Direct port of `axum::extract::Host`. Checks in order:
///   1. `Forwarded` header (RFC 7239)
///   2. `X-Forwarded-Host` header
///   3. `Host` header
///
/// ```swift
/// router.get("/") { (_: Host) in
///     return .plain("host: \($0.value)")
/// }
/// ```
public struct Host: Hashable, Sendable, CustomStringConvertible {
    public let value: String

    @inlinable public init(_ value: String) { self.value = value }
    public var description: String { value }
}

extension Host: FromRequestParts {

    public static func fromRequestParts<S: Sendable>(
        _ parts: inout RequestParts,
        state: borrowing S
    ) async throws -> Host {
        // 1. Forwarded header (RFC 7239): "host=example.com; proto=https"
        if let forwarded = parts.headers.first(for: .forwarded)?.description {
            // Parse "host=..." from the Forwarded value.
            for part in forwarded.split(separator: ";") {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                if trimmed.lowercased().hasPrefix("host=") {
                    let host = String(trimmed.dropFirst(5))
                    return Host(host)
                }
            }
        }

        // 2. X-Forwarded-Host
        if let xfh = parts.headers.first(for: .xForwardedHost)?.description {
            return Host(xfh)
        }

        // 3. Host header
        if let host = parts.headers.first(for: .host)?.description {
            return Host(host)
        }

        throw ExtractionRejection(
            "Host header not found in request",
            status: .badRequest
        )
    }
}

// MARK: - Extra HeaderName constants

extension HeaderName {
    /// `Forwarded` — RFC 7239.
    public static let forwarded = HeaderName("forwarded")
    /// `X-Forwarded-Host`.
    public static let xForwardedHost = HeaderName("x-forwarded-host")
}
