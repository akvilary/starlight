//===----------------------------------------------------------------------===//
//
//  ConnectInfo.swift
//  StarlightExtractors
//
//  Extractor conformance for ConnectInfo (defined in HTTP).
//
//===----------------------------------------------------------------------===//

import Foundation
import HTTP
import StarlightCore

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
