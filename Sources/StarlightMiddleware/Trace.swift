//===----------------------------------------------------------------------===//
//
//  Trace.swift
//  StarlightMiddleware
//
//  Direct port of `tower_http::trace::TraceLayer`.
//
//  Logs each request with method, path, status, and duration.
//  Configurable via hooks (on_request, on_response, on_failure).
//
//===----------------------------------------------------------------------===//

import Foundation
import HTTP
import StarlightCore
import StarlightTower

/// Configuration for `TraceLayer`. Mirrors `tower_http::trace::TraceLayer`.
public struct TraceConfig: Sendable {
    /// Called at the start of each request, before the handler runs.
    public var onRequest: @Sendable (Method, String) -> Void
    /// Called when the handler returns a response.
    public var onResponse: @Sendable (Method, String, StatusCode, Duration) -> Void
    /// Called when the handler throws.
    public var onFailure: @Sendable (Method, String, Duration, String) -> Void

    @inlinable public init(
        onRequest: @escaping @Sendable (Method, String) -> Void = { method, path in
            FileHandle.standardError.write("[req] \(method) \(path)\n".data(using: .utf8)!)
        },
        onResponse: @escaping @Sendable (Method, String, StatusCode, Duration) -> Void = { method, path, status, duration in
            let ms = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18 * 1000
            FileHandle.standardError.write(
                "[res] \(method) \(path) → \(status.code) (\(String(format: "%.2f", ms))ms)\n".data(using: .utf8)!
            )
        },
        onFailure: @escaping @Sendable (Method, String, Duration, String) -> Void = { method, path, duration, error in
            let ms = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18 * 1000
            FileHandle.standardError.write(
                "[err] \(method) \(path) ✗ \(error) (\(String(format: "%.2f", ms))ms)\n".data(using: .utf8)!
            )
        }
    ) {
        self.onRequest = onRequest
        self.onResponse = onResponse
        self.onFailure = onFailure
    }
}

/// Trace middleware layer — direct port of `tower_http::trace::TraceLayer`.
///
/// Wraps every request with logging. Default config writes to stderr:
///
/// ```
/// [req] GET /users/42
/// [res] GET /users/42 → 200 (0.45ms)
/// ```
///
/// Usage:
///
/// ```swift
/// let app = Router(state: ...)
///     .get("/", handler)
///     .layer(TraceLayer().asLayer())
/// ```
public struct TraceLayer: Sendable {
    public let config: TraceConfig

    @inlinable public init(config: TraceConfig = TraceConfig()) {
        self.config = config
    }

    /// Convert to a `Layer` that can be passed to `Router.layer(_:)`.
    public func asLayer() -> Layer<HTTP.Request<Body>, HTTP.Response<Body>> {
        Layer { inner in
            BoxService { request in
                let method = request.method
                let path = request.uri.pathString
                let start = ContinuousClock.now

                self.config.onRequest(method, path)

                do {
                    let response = try await inner.call(request)
                    let duration = ContinuousClock.now - start
                    self.config.onResponse(method, path, response.status, duration)
                    return response
                } catch {
                    let duration = ContinuousClock.now - start
                    self.config.onFailure(method, path, duration, "\(error)")
                    throw error
                }
            }
        }
    }
}
