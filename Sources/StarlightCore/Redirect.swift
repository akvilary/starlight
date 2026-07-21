//===----------------------------------------------------------------------===//
//
//  Redirect.swift
//  StarlightCore
//
//  Direct port of `axum::response::Redirect`.
//
//  Builds a redirect response (3xx) with the appropriate Location
//  header. Matches axum's API exactly: `to`, `permanent`,
//  `temporary`, `see_other`.
//
//===----------------------------------------------------------------------===//

import Foundation
import HTTP

/// A redirect response.
///
/// Direct port of `axum::response::Redirect`.
///
/// ```swift
/// router.get("/old") { _ in
///     Redirect.to("/new")
/// }
/// router.get("/gone") { _ in
///     Redirect.permanent("/new")
/// }
/// ```
public struct Redirect: IntoResponse, Sendable, Equatable {
    public let status: StatusCode
    public let location: String

    @inlinable
    public init(status: StatusCode, location: String) {
        self.status = status
        self.location = location
    }

    /// `302 Found` redirect (default — temporary, keeps method).
    /// Direct port of `Redirect::to`.
    public static func to(_ location: String) -> Redirect {
        Redirect(status: .found, location: location)
    }

    /// `301 Moved Permanently`. Some clients change POST → GET.
    /// Direct port of `Redirect::permanent`.
    public static func permanent(_ location: String) -> Redirect {
        Redirect(status: .movedPermanently, location: location)
    }

    /// `307 Temporary Redirect` (preserves method).
    /// Direct port of `Redirect::temporary`.
    public static func temporary(_ location: String) -> Redirect {
        Redirect(status: StatusCode(307), location: location)
    }

    /// `303 See Other` (redirects to GET after POST/PUT/DELETE).
    /// Direct port of `Redirect::see_other`.
    public static func seeOther(_ location: String) -> Redirect {
        Redirect(status: StatusCode(303), location: location)
    }

    // MARK: - IntoResponse

    public func intoResponse() -> HTTP.Response<Body> {
        var headers = HeaderMap()
        headers.insert(.location, location)
        headers.insert(.contentLength, "0")
        return HTTP.Response<Body>(status: status, headers: headers, body: .empty)
    }
}
