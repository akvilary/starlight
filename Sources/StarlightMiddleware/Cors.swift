//===----------------------------------------------------------------------===//
//
//  Cors.swift
//  StarlightMiddleware
//
//  Direct port of `tower_http::cors::CorsLayer`.
//
//  Handles CORS preflight (OPTIONS) requests and adds
//  Access-Control-Allow-* headers to responses.
//
//===----------------------------------------------------------------------===//

import Foundation
import HTTP
import StarlightCore
import Prism

/// CORS configuration — direct port of `tower_http::cors::CorsLayer`.
public struct CorsConfig: Sendable {
    /// Allowed origins. `["*"]` for any (default).
    public var allowedOrigins: [String]
    /// Allowed methods.
    public var allowedMethods: [Method]
    /// Allowed headers (by name).
    public var allowedHeaders: [String]
    /// Whether to expose credentials.
    public var allowCredentials: Bool
    /// Max-age for preflight cache (seconds).
    public var maxAge: Int

    @inlinable public init(
        allowedOrigins: [String] = ["*"],
        allowedMethods: [Method] = [.GET, .POST, .PUT, .DELETE, .OPTIONS, .PATCH],
        allowedHeaders: [String] = ["Content-Type", "Authorization"],
        allowCredentials: Bool = false,
        maxAge: Int = 600
    ) {
        self.allowedOrigins = allowedOrigins
        self.allowedMethods = allowedMethods
        self.allowedHeaders = allowedHeaders
        self.allowCredentials = allowCredentials
        self.maxAge = maxAge
    }
}

/// CORS middleware layer — direct port of `tower_http::cors::CorsLayer`.
///
/// **Preflight** (`OPTIONS` + `Origin` + `Access-Control-Request-Method`):
/// responds immediately with `Access-Control-Allow-*` headers if the
/// origin is allowed; returns 403 otherwise (policy not leaked).
///
/// **All other requests** (including non-preflight OPTIONS): forwarded
/// to the inner service, then `Access-Control-Allow-Origin` and
/// `Vary: Origin` are appended to the response.
///
/// `Vary: Origin` is ALWAYS set (both preflight and normal) to prevent
/// cache poisoning — CDNs must key on Origin when the server echoes
/// specific origins.
public struct CorsLayer: Sendable {
    public let config: CorsConfig

    @inlinable public init(config: CorsConfig = CorsConfig()) {
        self.config = config
    }

    public func asLayer() -> Layer<HTTP.Request, HTTP.Response> {
        let cfg = config
        return Layer { inner in
            BoxService { request in
                // Preflight: OPTIONS + Origin + Access-Control-Request-Method
                // (Fetch spec §3.2.3). All three required.
                if Self.isPreflight(request) {
                    return Self.preflightResponse(config: cfg, request: request)
                }
                // Non-preflight (including OPTIONS without CORS headers):
                // forward to handler, then add CORS response headers.
                var response = try await inner.call(request)
                Self.applyCorsHeaders(config: cfg, request: request, response: &response)
                return response
            }
        }
    }

    // MARK: - Helpers

    /// A CORS preflight request requires all three conditions
    /// (Fetch §3.2.3): method OPTIONS, Origin header present,
    /// Access-Control-Request-Method header present.
    @inline(__always)
    private static func isPreflight(_ request: Request) -> Bool {
        request.method == .OPTIONS
            && request.headers.first(for: .origin) != nil
            && request.headers.first(for: .accessControlRequestMethod) != nil
    }

    /// Check if the given origin is allowed by the config.
    @inline(__always)
    private static func isOriginAllowed(_ origin: String, config: CorsConfig) -> Bool {
        config.allowedOrigins.contains("*") || config.allowedOrigins.contains(origin)
    }

    @inline(__always)
    private static func preflightResponse(
        config: CorsConfig, request: Request
    ) -> HTTP.Response {
        var headers = HeaderMap()

        // Vary: Origin — preflight responses vary by origin.
        headers.append(.vary, "Origin")

        let origin = request.headers.first(for: .origin)?.description ?? ""

        guard isOriginAllowed(origin, config: config) else {
            // Origin not allowed — return 403 without Allow-* headers.
            // Browser blocks the preflight; API policy is not leaked.
            headers.insert(.contentLength, "0")
            return HTTP.Response(status: .forbidden, headers: headers, body: .empty)
        }

        // Origin allowed — echo it and expose the full policy.
        applyOriginHeader(config: config, request: request, headers: &headers)
        headers.insert(.accessControlAllowMethods,
                       config.allowedMethods.map(\.description).joined(separator: ", "))
        headers.insert(.accessControlAllowHeaders,
                       config.allowedHeaders.joined(separator: ", "))
        if config.allowCredentials {
            headers.insert(.accessControlAllowCredentials, "true")
        }
        headers.insert(.accessControlMaxAge, String(config.maxAge))
        headers.insert(.contentLength, "0")
        return HTTP.Response(status: .noContent, headers: headers, body: .empty)
    }

    @inline(__always)
    private static func applyCorsHeaders(
        config: CorsConfig, request: Request,
        response: inout HTTP.Response
    ) {
        // Vary: Origin — responses vary by origin when echoing
        // specific origins. Without this, CDNs serve one client's
        // CORS response to another (cache poisoning).
        response.headers.append(.vary, "Origin")
        applyOriginHeader(config: config, request: request, headers: &response.headers)
        if config.allowCredentials {
            response.headers.insert(.accessControlAllowCredentials, "true")
        }
    }

    @inline(__always)
    private static func applyOriginHeader(
        config: CorsConfig, request: Request,
        headers: inout HeaderMap
    ) {
        let origin = request.headers.first(for: .origin)?.description ?? ""

        if config.allowCredentials {
            // Access-Control-Allow-Origin: * is NOT compatible with
            // Access-Control-Allow-Credentials: true. Must echo the
            // specific origin.
            if isOriginAllowed(origin, config: config) && !origin.isEmpty {
                headers.insert(.accessControlAllowOrigin, origin)
            }
        } else {
            if config.allowedOrigins.contains("*") {
                headers.insert(.accessControlAllowOrigin, "*")
            } else if config.allowedOrigins.contains(origin) {
                headers.insert(.accessControlAllowOrigin, origin)
            }
        }
    }
}

// MARK: - Extra HeaderName constants for CORS

extension HeaderName {
    /// `Access-Control-Allow-Origin`
    public static let accessControlAllowOrigin = HeaderName("access-control-allow-origin")
    /// `Access-Control-Allow-Methods`
    public static let accessControlAllowMethods = HeaderName("access-control-allow-methods")
    /// `Access-Control-Allow-Headers`
    public static let accessControlAllowHeaders = HeaderName("access-control-allow-headers")
    /// `Access-Control-Allow-Credentials`
    public static let accessControlAllowCredentials = HeaderName("access-control-allow-credentials")
    /// `Access-Control-Max-Age`
    public static let accessControlMaxAge = HeaderName("access-control-max-age")
    /// `Origin`
    public static let origin = HeaderName("origin")
    /// `Access-Control-Request-Method` (sent by browser on preflight)
    public static let accessControlRequestMethod = HeaderName("access-control-request-method")
    /// `Access-Control-Request-Headers` (sent by browser on preflight)
    public static let accessControlRequestHeaders = HeaderName("access-control-request-headers")
}
