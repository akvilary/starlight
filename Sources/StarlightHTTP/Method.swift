//===----------------------------------------------------------------------===//
//
//  Method.swift
//  StarlightHTTP
//
//  HTTP request method. Direct port of `http::Method`.
//
//===----------------------------------------------------------------------===//

import Foundation

/// HTTP request method.
///
/// Covers the standard set plus arbitrary extension methods via
/// `.other(rawValue:)`. Matches `http::Method` (Rust) 1:1.
public struct Method: Sendable, Hashable, CustomStringConvertible {
    /// Raw uppercase ASCII bytes. Stored as `SmallAscii`-style:
    /// inline for ≤ 7 bytes, heap-allocated otherwise.
    @usableFromInline internal let storage: MethodStorage

    @usableFromInline
    internal enum MethodStorage: Sendable, Hashable {
        case inline(UInt64, UInt8)  // bits + length, max 7 bytes inline
        case heap([UInt8])
    }

    @inlinable
    internal init(bytes: [UInt8]) {
        if bytes.count <= 7 {
            var bits: UInt64 = 0
            for b in bytes {
                bits = (bits << 8) | UInt64(b)
            }
            self.storage = .inline(bits, UInt8(bytes.count))
        } else {
            self.storage = .heap(bytes)
        }
    }

    /// Construct from an arbitrary ASCII string.
    public init(_ raw: String) {
        self.init(bytes: Array(raw.utf8))
    }

    /// Construct from raw bytes — used by the parser to avoid a
    /// `String` materialisation.
    @inlinable
    public init(bytes: UnsafeBufferPointer<UInt8>) {
        self.init(bytes: Array(bytes))
    }

    // ── Standard methods ────────────────────────────────────────────

    public static let GET     = Method("GET")
    public static let POST    = Method("POST")
    public static let PUT     = Method("PUT")
    public static let DELETE  = Method("DELETE")
    public static let HEAD    = Method("HEAD")
    public static let OPTIONS = Method("OPTIONS")
    public static let CONNECT = Method("CONNECT")
    public static let PATCH   = Method("PATCH")
    public static let TRACE   = Method("TRACE")

    /// Whether this is one of the standard methods. axum uses this
    /// in `MethodRouter` to switch on a fixed set of methods with
    /// a fallback for extension methods.
    public var isStandard: Bool {
        switch self {
        case .GET, .POST, .PUT, .DELETE, .HEAD, .OPTIONS, .CONNECT, .PATCH, .TRACE:
            return true
        default:
            return false
        }
    }

    /// `true` if the method is safe per RFC 7231 §4.2.1 — i.e. the
    /// method is read-only and cacheable.
    public var isSafe: Bool {
        switch self {
        case .GET, .HEAD, .OPTIONS, .TRACE: return true
        default: return false
        }
    }

    /// `true` for idempotent methods (RFC 7231 §4.2.2).
    public var isIdempotent: Bool {
        switch self {
        case .GET, .HEAD, .OPTIONS, .TRACE, .PUT, .DELETE: return true
        default: return false
        }
    }

    public var description: String {
        switch storage {
        case .inline(let bits, let len):
            var bytes: [UInt8] = []
            bytes.reserveCapacity(Int(len))
            for i in 0..<Int(len) {
                let shift = (Int(len) - 1 - i) * 8
                bytes.append(UInt8(truncatingIfNeeded: bits >> shift))
            }
            return String(decoding: bytes, as: UTF8.self)
        case .heap(let bytes):
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}

extension Method: Equatable {
    @inlinable
    public static func == (lhs: Method, rhs: Method) -> Bool {
        switch (lhs.storage, rhs.storage) {
        case (.inline(let a, let la), .inline(let b, let lb)):
            return la == lb && a == b
        case (.heap(let a), .heap(let b)):
            return a == b
        default:
            return false
        }
    }
}
