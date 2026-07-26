//===----------------------------------------------------------------------===//
//
//  Query.swift
//  StarlightExtractors
//
//  Direct port of `axum::extract::Query<T>`.
//
//===----------------------------------------------------------------------===//

import Foundation
import StarlightCore
import HTTP

/// Extractor for URL query parameters.
///
/// Decodes `?key=value&key2=value2` into `T: Decodable`.
public struct Query<T: Decodable & Sendable>: Sendable {
    public let value: T

    @inlinable public init(_ value: T) { self.value = value }
}

extension Query: FromRequestParts {
    public typealias State = AnySendable

    public static func fromRequestParts(
        _ parts: inout RequestParts,
        state: borrowing AnySendable
    ) async throws -> Query<T> {
        // Parse query string into [(String, String)] entries.
        // Empty query → empty entries → optional fields decode as nil.
        let rawBytes = parts.uri.queryBytes ?? []
        var entries: [(String, String)] = []
        var key: [UInt8] = []
        var val: [UInt8] = []
        var inValue = false
        for b in rawBytes {
            switch b {
            case 0x26:  // '&'
                if !key.isEmpty {
                    entries.append((Self.decode(key), Self.decode(val)))
                }
                key.removeAll(keepingCapacity: true)
                val.removeAll(keepingCapacity: true)
                inValue = false
            case 0x3D:  // '='
                inValue = true
            default:
                if inValue { val.append(b) } else { key.append(b) }
            }
        }
        if !key.isEmpty {
            entries.append((Self.decode(key), Self.decode(val)))
        }

        // Decode via StringKeyedDecoder — coerces String→Int/Double/Bool,
        // handles Optional fields via decodeNil. Same decoder used by
        // Path<T>, ensuring consistent decoding semantics.
        do {
            let decoded = try StringKeyedDecoder.decode(entries, into: T.self)
            return Query(decoded)
        } catch {
            throw ExtractionRejection("query decode failed: \(error)", status: .badRequest)
        }
    }

    /// URL-decode a query key or value. Per application/x-www-form-urlencoded
    /// (RFC 1866 §8.2.1): `+` → space, `%XX` → byte.
    @inline(__always)
    private static func decode(_ bytes: [UInt8]) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x2B {  // '+' → space (query-string convention)
                out.append(0x20)
            } else if b == 0x25, i + 2 < bytes.count {  // '%XX'
                if let hi = Self.hexDigit(bytes[i + 1]),
                   let lo = Self.hexDigit(bytes[i + 2]) {
                    out.append(UInt8(hi * 16 + lo))
                    i += 2
                } else {
                    out.append(b)
                }
            } else {
                out.append(b)
            }
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    @inline(__always)
    private static func hexDigit(_ b: UInt8) -> Int? {
        switch b {
        case 0x30...0x39: return Int(b - 0x30)
        case 0x41...0x46: return Int(b - 0x41 + 10)
        case 0x61...0x66: return Int(b - 0x61 + 10)
        default: return nil
        }
    }
}
