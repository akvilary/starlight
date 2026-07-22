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
import StarlightTower

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
/// - For `OPTIONS` preflight requests: responds immediately with
///   the appropriate `Access-Control-Allow-*` headers.
/// - For all other requests: adds CORS headers to the response.
///
/// ```swift
/// let app = Router(state: ...)
///     .get("/api/data", handler)
///     .layer(CorsLayer(config: CorsConfig(
///         allowedOrigins: ["https://myapp.com"],
///         allowCredentials: true
///     )).asLayer())
/// ```
public struct CorsLayer: Sendable {
    public let config: CorsConfig

    @inlinable public init(config: CorsConfig = CorsConfig()) {
        self.config = config
    }

    public func asLayer() -> Layer<HTTP.Request, HTTP.Response> {
        let cfg = config
        return Layer { inner in
            BoxService { request in
                // Handle preflight OPTIONS immediately.
                if request.method == .OPTIONS {
                    return Self.preflightResponse(config: cfg, request: request)
                }
                // Normal request: forward to handler, then add CORS headers.
                var response = try await inner.call(request)
                Self.applyCorsHeaders(config: cfg, request: request, response: &response)
                return response
            }
        }
    }

    // MARK: - Helpers

    @inline(__always)
    private static func preflightResponse(
        config: CorsConfig, request: Request
    ) -> HTTP.Response {
        var headers = HeaderMap()
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

        // B4 FIX: per CORS spec, Access-Control-Allow-Origin: * is
        // NOT compatible with Access-Control-Allow-Credentials: true.
        // When credentials are enabled, must echo the specific origin.
        if config.allowCredentials {
            // Must echo specific origin.
            if config.allowedOrigins.contains("*") || config.allowedOrigins.contains(origin) {
                if !origin.isEmpty {
                    headers.insert(.accessControlAllowOrigin, origin)
                }
            }
        } else {
            // Without credentials, '*' is fine.
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
}
