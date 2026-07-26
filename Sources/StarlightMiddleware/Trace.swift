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
import Prism

/// Configuration for `TraceLayer`. Mirrors `tower_http::trace::TraceLayer`.
///
/// By default, all hooks are no-ops — zero per-request overhead.
/// Provide closures to opt into logging. This matches axum's
/// `tracing` integration (which is also opt-in — you configure
/// the subscriber, not the layer itself).
public struct TraceConfig: Sendable {
    /// Called at the start of each request, before the handler runs.
    public var onRequest: @Sendable (Method, String) -> Void
    /// Called when the handler returns a response.
    public var onResponse: @Sendable (Method, String, StatusCode, Duration) -> Void
    /// Called when the handler throws.
    public var onFailure: @Sendable (Method, String, Duration, String) -> Void

    @inlinable public init(
        onRequest: @escaping @Sendable (Method, String) -> Void = { _, _ in },
        onResponse: @escaping @Sendable (Method, String, StatusCode, Duration) -> Void = { _, _, _, _ in },
        onFailure: @escaping @Sendable (Method, String, Duration, String) -> Void = { _, _, _, _ in }
    ) {
        self.onRequest = onRequest
        self.onResponse = onResponse
        self.onFailure = onFailure
    }

    /// Stderr logging config — prints `[req]` / `[res]` / `[err]` lines.
    /// Use sparingly: adds ~1µs per request from the stderr write syscall.
    public static let stderr = TraceConfig(
        onRequest: { method, path in
            FileHandle.standardError.write("[req] \(method) \(path)\n".data(using: .utf8)!)
        },
        onResponse: { method, path, status, duration in
            let ms = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18 * 1000
            FileHandle.standardError.write(
                "[res] \(method) \(path) → \(status.code) (\(String(format: "%.2f", ms))ms)\n".data(using: .utf8)!
            )
        },
        onFailure: { method, path, duration, error in
            let ms = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18 * 1000
            FileHandle.standardError.write(
                "[err] \(method) \(path) ✗ \(error) (\(String(format: "%.2f", ms))ms)\n".data(using: .utf8)!
            )
        }
    )
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
    public func asLayer() -> Layer<HTTP.Request, HTTP.Response> {
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
