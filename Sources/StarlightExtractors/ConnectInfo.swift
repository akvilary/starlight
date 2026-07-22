//===----------------------------------------------------------------------===//
//
//  ConnectInfo.swift
//  StarlightExtractors
//
//  Direct port of `axum::extract::ConnectInfo<Addr>`.
//
//  Provides the peer's socket address — set by the server when the
//  connection is accepted. Extracted via `Request.extensions`.
//
//===----------------------------------------------------------------------===//

import Foundation
import HTTP
import StarlightCore

/// Extractor for the peer's socket address.
///
/// Direct port of `axum::extract::ConnectInfo<Addr>`. Set by the
/// server when a connection is accepted — the worker stashes the
/// peer address in `Request.extensions`.
///
/// ```swift
/// router.get("/whoami") { (ci: ConnectInfo) in
///     return .plain("peer: \(ci.description)")
/// }
/// ```
public struct ConnectInfo: Hashable, Sendable, CustomStringConvertible {
    /// Best-effort peer address string — typically "ip:port".
    public let peerAddress: String

    @inlinable public init(peerAddress: String) {
        self.peerAddress = peerAddress
    }

    public var description: String { peerAddress }
}

extension ConnectInfo: FromRequestParts {
    public typealias State = AnySendable

    public static func fromRequestParts(
        _ parts: inout RequestParts,
        state: borrowing AnySendable
    ) async throws -> ConnectInfo {
        if let info = parts.extensions.get(ConnectInfo.self) {
            return info
        }
        throw ExtractionRejection(
            "ConnectInfo not set on request — server didn't populate it",
            status: .internalServerError
        )
    }
}

/// Extension point for the server. The worker calls this on each
/// accepted connection to stash the peer address in the request.
@inlinable
public func setConnectInfo(_ peerAddress: String, on request: inout Request) {
    request.extensions.insert(ConnectInfo(peerAddress: peerAddress))
}
