//===----------------------------------------------------------------------===//
//
//  StatusCode.swift
//  StarlightHTTP
//
//  HTTP response status code. Port of `http::StatusCode`.
//
//===----------------------------------------------------------------------===//

import Foundation

/// HTTP response status code (RFC 9110 §15).
///
/// Stored as the raw 16-bit integer the wire protocol carries.
/// Helpers classify by class (1xx informational, 2xx success, …).
public struct StatusCode: Sendable, Hashable, CustomStringConvertible {
    /// The 3-digit status code, in 100...599.
    public let code: UInt16

    /// Construct from an integer. Traps outside the valid range,
    /// matching `http::StatusCode::from_u16` (which returns `Result`
    /// in Rust; here we precondition because every callsite is
    /// either a constant or already-validated user input).
    @inlinable
    public init(_ code: UInt16) {
        precondition((100...599).contains(code),
                     "StatusCode: \(code) is outside the valid 100...599 range")
        self.code = code
    }

    @inlinable
    public init(_ code: Int) {
        self.init(UInt16(code))
    }

    /// Canonical reason phrase for the code, or "Unknown" if not
    /// a registered value. RFC 9110 §15.
    public var canonicalReason: String {
        switch code {
        case 100: return "Continue"
        case 101: return "Switching Protocols"
        case 200: return "OK"
        case 201: return "Created"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 206: return "Partial Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 303: return "See Other"
        case 304: return "Not Modified"
        case 307: return "Temporary Redirect"
        case 308: return "Permanent Redirect"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 406: return "Not Acceptable"
        case 408: return "Request Timeout"
        case 409: return "Conflict"
        case 410: return "Gone"
        case 411: return "Length Required"
        case 412: return "Precondition Failed"
        case 413: return "Payload Too Large"
        case 414: return "URI Too Long"
        case 415: return "Unsupported Media Type"
        case 422: return "Unprocessable Entity"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        case 505: return "HTTP Version Not Supported"
        default: return "Unknown"
        }
    }

    // ── Class predicates (RFC 9110 §15) ───────────────────────────

    @inlinable public var isInformational: Bool { (100...199).contains(code) }
    @inlinable public var isSuccess:      Bool { (200...299).contains(code) }
    @inlinable public var isRedirection:  Bool { (300...399).contains(code) }
    @inlinable public var isClientError:  Bool { (400...499).contains(code) }
    @inlinable public var isServerError:  Bool { (500...599).contains(code) }

    public var description: String { "\(code) \(canonicalReason)" }

    // ── Common codes ───────────────────────────────────────────────

    public static let ok                  = StatusCode(200)
    public static let created             = StatusCode(201)
    public static let noContent           = StatusCode(204)
    public static let movedPermanently    = StatusCode(301)
    public static let found               = StatusCode(302)
    public static let notModified         = StatusCode(304)
    public static let badRequest          = StatusCode(400)
    public static let unauthorized        = StatusCode(401)
    public static let forbidden           = StatusCode(403)
    public static let notFound            = StatusCode(404)
    public static let methodNotAllowed    = StatusCode(405)
    public static let requestTimeout      = StatusCode(408)
    public static let conflict            = StatusCode(409)
    public static let payloadTooLarge     = StatusCode(413)
    public static let uriTooLong          = StatusCode(414)
    public static let unsupportedMediaType = StatusCode(415)
    public static let unprocessableEntity = StatusCode(422)
    public static let tooManyRequests     = StatusCode(429)
    public static let internalServerError = StatusCode(500)
    public static let notImplemented      = StatusCode(501)
    public static let badGateway          = StatusCode(502)
    public static let serviceUnavailable  = StatusCode(503)
    public static let gatewayTimeout      = StatusCode(504)
}
