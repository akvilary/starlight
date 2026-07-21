//===----------------------------------------------------------------------===//
//
//  Version.swift
//  StarlightHTTP
//
//  HTTP protocol version. Port of `http::Version`.
//
//===----------------------------------------------------------------------===//

import Foundation

/// HTTP protocol version.
public enum Version: Sendable, Hashable, CustomStringConvertible {
    case http09
    case http10
    case http11
    case http2
    case http3

    public var description: String {
        switch self {
        case .http09: return "HTTP/0.9"
        case .http10: return "HTTP/1.0"
        case .http11: return "HTTP/1.1"
        case .http2:  return "HTTP/2"
        case .http3:  return "HTTP/3"
        }
    }
}
