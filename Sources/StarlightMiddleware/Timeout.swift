//===----------------------------------------------------------------------===//
//
//  Timeout.swift
//  StarlightMiddleware
//
//  Direct port of `tower::timeout::TimeoutLayer`.
//
//  Aborts requests that take longer than the configured duration.
//  Returns 504 Gateway Timeout on expiry.
//
//===----------------------------------------------------------------------===//

import Foundation
import HTTP
import StarlightCore
import StarlightTower

/// Timeout middleware layer — direct port of `tower::timeout::Timeout`.
///
/// Wraps each request in a race between the handler and a timer.
/// If the timer fires first, returns 504 Gateway Timeout.
///
/// ```swift
/// let app = Router(state: ...)
///     .get("/slow", slowHandler)
///     .layer(TimeoutLayer(duration: .seconds(10)).asLayer())
/// ```
public struct TimeoutLayer: Sendable {
    public let duration: Duration

    @inlinable public init(duration: Duration) {
        self.duration = duration
    }

    public func asLayer() -> Layer<HTTP.Request<Body>, HTTP.Response<Body>> {
        let timeout = duration
        return Layer { inner in
            BoxService { request in
                let method = request.method
                let path = request.uri.pathString

                let result = await withTaskGroup(
                    of: HTTP.Response<Body>?.self,
                    returning: HTTP.Response<Body>?.self
                ) { group in
                    // Race: handler vs timeout
                    group.addTask {
                        try? await inner.call(request)
                    }
                    group.addTask {
                        try? await Task.sleep(for: timeout)
                        return nil  // timeout fired
                    }
                    let first = await group.next()
                    group.cancelAll()
                    return first ?? nil
                }

                guard let response = result else {
                    // Timeout — return 504
                    var headers = HeaderMap()
                    headers.insert(.contentType, "text/plain; charset=utf-8")
                    let body = "Gateway Timeout: \(method) \(path) exceeded \(timeout)\n"
                    headers.insert(.contentLength, String(body.utf8.count))
                    return HTTP.Response<Body>(
                        status: .gatewayTimeout,
                        headers: headers,
                        body: .buffered(Array(body.utf8))
                    )
                }
                return response
            }
        }
    }
}
