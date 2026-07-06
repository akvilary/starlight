//===----------------------------------------------------------------------===//
//
//  HTTPStatus.swift
//  StarlightHTTP
//
//  Phase 0 placeholder — full set lands in Phase 2.
//
//===----------------------------------------------------------------------===//

/// HTTP response status code.
public struct HTTPStatus: Sendable, Hashable {
    public let code: Int
    public let reasonPhrase: String

    @inlinable
    public init(_ code: Int, reasonPhrase: String? = nil) {
        self.code = code
        self.reasonPhrase = reasonPhrase ?? HTTPStatus.defaultReason(for: code)
    }

    public static let ok = HTTPStatus(200)
    public static let notFound = HTTPStatus(404)
    public static let internalServerError = HTTPStatus(500)

    @usableFromInline
    static func defaultReason(for code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 304: return "Not Modified"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 414: return "URI Too Long"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        default: return "Unknown"
        }
    }
}
