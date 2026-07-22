//===----------------------------------------------------------------------===//
//
//  RateLimit.swift
//  StarlightMiddleware
//
//  Direct port of `tower::limit::rate::RateLimitLayer`.
//
//  Per-key (typically per-IP) sliding-window rate limiter. Returns
//  429 Too Many Requests when the limit is exceeded.
//
//===----------------------------------------------------------------------===//

import Foundation
import Synchronization
import HTTP
import StarlightCore
import StarlightExtractors
import StarlightTower

/// Per-key request counter. Uses a fixed-window algorithm: each key
/// (typically the client IP) gets `maxRequests` per `windowDuration`.
/// When the window expires, the counter resets.
///
/// Thread-safe via `Mutex`. Sync access — no async overhead.
public final class RateLimiter: Sendable {
    @usableFromInline
    internal struct Window {
        var count: Int
        var windowStart: ContinuousClock.Instant
    }

    @usableFromInline
    internal let mutex: Mutex<[String: Window]>
    public let maxRequests: Int
    public let windowDuration: Duration

    @inlinable
    public init(maxRequests: Int, windowDuration: Duration = .seconds(1)) {
        self.maxRequests = maxRequests
        self.windowDuration = windowDuration
        self.mutex = Mutex([:])
    }

    /// Returns `true` if the request is allowed (and consumes a token).
    /// Returns `false` if the rate limit is exceeded.
    @discardableResult
    public func allow(_ key: String) -> Bool {
        mutex.withLock { windows in
            let now = ContinuousClock.now
            if var window = windows[key] {
                // Check if the window has expired.
                if now - window.windowStart >= windowDuration {
                    window.count = 1
                    window.windowStart = now
                    windows[key] = window
                    return true
                }
                // Same window — check count.
                if window.count >= maxRequests {
                    return false
                }
                window.count += 1
                windows[key] = window
                return true
            }
            // First request from this key.
            windows[key] = Window(count: 1, windowStart: now)
            return true
        }
    }

    /// Evict expired windows to prevent unbounded memory growth.
    /// Call periodically (e.g., every 60s) from a background Task.
    public func evictExpired() {
        let now = ContinuousClock.now
        mutex.withLock { windows in
            windows = windows.filter { _, window in
                now - window.windowStart < windowDuration * 2
            }
        }
    }
}

/// Rate-limit middleware layer — direct port of
/// `tower::limit::rate::RateLimit`.
///
/// Wraps each request with a rate-limit check. The key is extracted
/// from the request (typically the client IP via `ConnectInfo`).
///
/// ```swift
/// let limiter = RateLimiter(maxRequests: 100, windowDuration: .seconds(60))
/// let app = Router(state: ...)
///     .get("/api", handler)
/// let service = RateLimitLayer(limiter: limiter).asLayer()
///     .layer(BoxService(app))
/// ```
public struct RateLimitLayer: Sendable {
    public let limiter: RateLimiter
    public let keyExtractor: @Sendable (HTTP.Request) -> String

    @inlinable
    public init(
        limiter: RateLimiter,
        keyExtractor: @Sendable @escaping (HTTP.Request) -> String = { req in
            // Default: use ConnectInfo if available, otherwise "global".
            req.extensions.get(ConnectInfo.self)?.peerAddress ?? "global"
        }
    ) {
        self.limiter = limiter
        self.keyExtractor = keyExtractor
    }

    public func asLayer() -> Layer<HTTP.Request, HTTP.Response> {
        let limiter = self.limiter
        let extractKey = self.keyExtractor
        return Layer { inner in
            BoxService { request in
                let key = extractKey(request)
                if !limiter.allow(key) {
                    // Rate limited — return 429.
                    let body = "Too Many Requests\n"
                    var headers = HeaderMap()
                    headers.insert(.contentType, "text/plain; charset=utf-8")
                    headers.insert(.contentLength, String(body.utf8.count))
                    headers.insert(.retryAfter, "1")
                    return HTTP.Response(
                        status: .tooManyRequests,
                        headers: headers,
                        body: .buffered(Array(body.utf8))
                    )
                }
                return try await inner.call(request)
            }
        }
    }
}

// MARK: - Extra HeaderName constants

extension HeaderName {
    /// `Retry-After` — RFC 9110 §10.2.3.
    public static let retryAfter = HeaderName("retry-after")
}
