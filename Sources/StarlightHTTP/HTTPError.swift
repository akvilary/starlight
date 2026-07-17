//===----------------------------------------------------------------------===//
//
//  HTTPError.swift
//  StarlightHTTP
//
//  Typed HTTP errors that handlers can `throw`. The codec catches
//  `HTTPError` separately from `any Error` and synthesises a response
//  with the matching status code (instead of the default 500).
//
//  Usage:
//
//      builder.get("/users/:id") { ctx async in
//          guard let user = try await db.find(ctx.params["id"]) else {
//              throw HTTPError.notFound
//          }
//          return .json(user)
//      }
//
//  For custom error bodies, build an `HTTPResponse` directly —
//  `HTTPError` covers the common status codes with default messages.
//
//===----------------------------------------------------------------------===//

/// Typed HTTP error. Throw from a handler to produce a response with
/// a specific status code (instead of the default 500 for arbitrary
/// errors).
///
/// The codec inspects every thrown error: if it is an `HTTPError`,
/// the corresponding status code and a default body are used; any
/// other `Error` still produces a 500 Internal Server Error.
public enum HTTPError: Error, Sendable, Equatable {
    /// 400 Bad Request
    case badRequest
    /// 401 Unauthorized
    case unauthorized
    /// 403 Forbidden
    case forbidden
    /// 404 Not Found
    case notFound
    /// 405 Method Not Allowed
    case methodNotAllowed
    /// 409 Conflict
    case conflict
    /// 413 Payload Too Large
    case payloadTooLarge
    /// 429 Too Many Requests
    case tooManyRequests
    /// 500 Internal Server Error
    case internalError
    /// 501 Not Implemented
    case notImplemented
    /// 502 Bad Gateway
    case badGateway
    /// 503 Service Unavailable
    case serviceUnavailable
    /// 504 Gateway Timeout
    case gatewayTimeout

    /// The HTTP status code for this error.
    public var status: HTTPStatus {
        switch self {
        case .badRequest:         return HTTPStatus(400)
        case .unauthorized:       return HTTPStatus(401)
        case .forbidden:          return HTTPStatus(403)
        case .notFound:           return HTTPStatus(404)
        case .methodNotAllowed:   return HTTPStatus(405)
        case .conflict:           return HTTPStatus(409)
        case .payloadTooLarge:    return HTTPStatus(413)
        case .tooManyRequests:    return HTTPStatus(429)
        case .internalError:      return HTTPStatus(500)
        case .notImplemented:     return HTTPStatus(501)
        case .badGateway:         return HTTPStatus(502)
        case .serviceUnavailable: return HTTPStatus(503)
        case .gatewayTimeout:     return HTTPStatus(504)
        }
    }

    /// Default response body for this error (without trailing newline).
    public var defaultMessage: String {
        switch self {
        case .badRequest:         return "400 Bad Request"
        case .unauthorized:       return "401 Unauthorized"
        case .forbidden:          return "403 Forbidden"
        case .notFound:           return "404 Not Found"
        case .methodNotAllowed:   return "405 Method Not Allowed"
        case .conflict:           return "409 Conflict"
        case .payloadTooLarge:    return "413 Payload Too Large"
        case .tooManyRequests:    return "429 Too Many Requests"
        case .internalError:      return "500 Internal Server Error"
        case .notImplemented:     return "501 Not Implemented"
        case .badGateway:         return "502 Bad Gateway"
        case .serviceUnavailable: return "503 Service Unavailable"
        case .gatewayTimeout:     return "504 Gateway Timeout"
        }
    }
}
