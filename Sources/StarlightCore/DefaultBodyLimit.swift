//===----------------------------------------------------------------------===//
//
//  DefaultBodyLimit.swift
//  StarlightCore
//
//  Direct port of `axum::extract::DefaultBodyLimit`.
//
//  Layer that sets the maximum request body size. Extractors that
//  call `Body.collect(maxBytes:)` read the limit from extensions.
//  Returns 413 Payload Too Large when exceeded.
//
//===----------------------------------------------------------------------===//

import Foundation
import HTTP
import Prism

/// Maximum request body size, set via a Layer and read from
/// `Request.extensions` by body-consuming extractors.
///
/// Direct port of `axum::extract::DefaultBodyLimit`.
public struct DefaultBodyLimit: Hashable, Sendable {
    public let maxBytes: Int

    @inlinable public init(maxBytes: Int) {
        self.maxBytes = maxBytes
    }

    /// Default limit: 2 MB (matches axum's default).
    public static let default_ = DefaultBodyLimit(maxBytes: 2 * 1024 * 1024)

    /// Create a Layer that inserts this limit into every request's
    /// extensions. Applied via `Router.layer` or `ServiceBuilder`.
    public static func layer(_ limit: DefaultBodyLimit = .default_)
        -> Layer<HTTP.Request, HTTP.Response>
    {
        let l = limit
        return Layer { inner in
            BoxService { request in
                var req = request
                req.extensions.insert(l)
                return try await inner.call(req)
            }
        }
    }

    /// Read the limit from request extensions, if set.
    /// Returns Int.max if no limit is configured.
    public static func read(from extensions: Extensions) -> Int {
        extensions.get(DefaultBodyLimit.self)?.maxBytes ?? Int.max
    }
}
