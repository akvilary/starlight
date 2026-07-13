//===----------------------------------------------------------------------===//
//
//  HTTPMethod.swift
//  StarlightHTTP
//
//  Phase 0 placeholder — full set lands in Phase 2 along with the SIMD parser.
//  The type is shaped already so that other modules can reference it.
//
//===----------------------------------------------------------------------===//

/// HTTP request method.
///
/// Stored as an enum case for routing; the parser will provide an
/// `init(span:)` constructor in Phase 2 that matches the raw byte view
/// directly out of the receive buffer without allocating a `String`.
public enum HTTPMethod: Sendable, Hashable {
    case GET
    case POST
    case PUT
    case PATCH
    case DELETE
    case HEAD
    case OPTIONS
    case CONNECT
    case TRACE
    case other(raw: String)

    @inlinable
    public var isOther: Bool {
        if case .other = self { return true } else { return false }
    }

    @inlinable
    public init() {
        self = .other(raw: "")
    }
}
