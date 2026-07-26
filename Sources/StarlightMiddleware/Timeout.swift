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
import Prism

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

    public func asLayer() -> Layer<HTTP.Request, HTTP.Response> {
        let timeout = duration
        return Layer { inner in
            BoxService { request in
                let method = request.method
                let path = request.uri.pathString

                // Race: handler vs timer.
                //
                // The handler task catches errors internally and maps
                // them to a 500 Response. This ensures that nil from
                // group.next() means ONLY "timeout" — not a collapsed
                // handler error (the original bug with `try?`).
                //
                // withTaskGroup waits for both tasks to finish after
                // cancelAll(). For async handlers this is microseconds
                // (Task.sleep and await points respect cancellation).
                // For CPU-bound handlers without await points, the
                // group hangs — this is a general Swift Concurrency
                // limitation, not specific to this middleware.
                let result = await withTaskGroup(
                    of: HTTP.Response?.self,
                    returning: HTTP.Response?.self
                ) { group in
                    group.addTask { () -> HTTP.Response? in
                        do {
                            return try await inner.call(request)
                        } catch {
                            var h = HeaderMap()
                            h.insert(.contentType, "text/plain; charset=utf-8")
                            let msg = "Internal Server Error"
                            h.insert(.contentLength, String(msg.utf8.count))
                            return HTTP.Response(
                                status: .internalServerError,
                                headers: h,
                                body: .buffered(Array(msg.utf8))
                            )
                        }
                    }
                    group.addTask {
                        try? await Task.sleep(for: timeout)
                        return nil  // timeout fired
                    }
                    let first = await group.next() ?? nil
                    group.cancelAll()
                    return first
                }

                guard let response = result else {
                    // Timeout — return 504
                    var headers = HeaderMap()
                    headers.insert(.contentType, "text/plain; charset=utf-8")
                    let body = "Gateway Timeout: \(method) \(path) exceeded \(timeout)\n"
                    headers.insert(.contentLength, String(body.utf8.count))
                    return HTTP.Response(
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
