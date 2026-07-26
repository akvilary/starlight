//===----------------------------------------------------------------------===//
//
//  PathParams.swift
//  StarlightCore
//
//  Mutable accumulator for matched path params + the wrapper type
//  stashed in `Request.extensions` so the `Path<T>` extractor can
//  read captured path params without re-matching. axum uses a
//  similar mechanism internally (`RawPathParams`).
//
//===----------------------------------------------------------------------===//

import Foundation

/// Mutable accumulator for matched path params.
///
/// During routing, captured segments (`:id`, `*path`) are pushed
/// here. The `Path<T>` extractor then decodes this into a concrete
/// `Decodable` type.
public struct PathParams: Sendable {
    @usableFromInline
    internal var entries: [(String, String)] = []

    @inlinable public init() {}

    @inlinable
    public mutating func set(_ name: String, value: String) {
        entries.append((name, value))
    }

    @inlinable
    public func get(_ name: String) -> String? {
        for (n, v) in entries where n == name { return v }
        return nil
    }

    /// Reset for re-use across route-matching attempts.
    @inlinable
    public mutating func removeAll(keepingCapacity: Bool = false) {
        entries.removeAll(keepingCapacity: keepingCapacity)
    }

    /// Decode into a concrete `Decodable` type — used by the
    /// `Path<T>` extractor.
    public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try PathParamsDecoder.decode(entries, into: T.self)
    }

    @inlinable public var count: Int { entries.count }
    @inlinable public var isEmpty: Bool { entries.isEmpty }
}

/// Wrapper type stashed in `Request.extensions` so the `Path<T>`
/// extractor can read captured path params without re-matching.
public struct MatchedPathParams: Hashable, Sendable {
    public let params: PathParams
    @inlinable public init(_ params: PathParams) { self.params = params }

    public func hash(into hasher: inout Hasher) {
        for (n, v) in params.entries {
            hasher.combine(n)
            hasher.combine(v)
        }
    }
    public static func == (lhs: MatchedPathParams, rhs: MatchedPathParams) -> Bool {
        guard lhs.params.entries.count == rhs.params.entries.count else { return false }
        for (i, (ln, lv)) in lhs.params.entries.enumerated() {
            let (rn, rv) = rhs.params.entries[i]
            if ln != rn || lv != rv { return false }
        }
        return true
    }
}

/// Tiny ad-hoc decoder for `Path<T>` / `Query<T>` — supports struct
/// cases with primitive `Decodable` fields. A full CodingKeys-
/// robust implementation lives in StarlightExtractors (built on
/// `JSONSerialization`).
@usableFromInline
internal enum PathParamsDecoder {
    static func decode<T: Decodable>(_ entries: [(String, String)], into type: T.Type) throws -> T {
        let decoder = PathKeyedDecoder(entries: entries)
        return try T(from: decoder)
    }
}

@usableFromInline
internal struct PathKeyedDecoder: Decoder {
    @usableFromInline internal let entries: [(String, String)]

    @inlinable init(entries: [(String, String)]) { self.entries = entries }

    public var codingPath: [CodingKey] { [] }
    public var userInfo: [CodingUserInfoKey: Any] { [:] }

    public func container<Key>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key>
    where Key: CodingKey {
        KeyedDecodingContainer(PathKeyedContainer(entries: entries, codingPath: []))
    }
    public func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        throw DecodingError.typeMismatch(Any.self, .init(codingPath: [], debugDescription: "unkeyed not supported"))
    }
    public func singleValueContainer() throws -> SingleValueDecodingContainer {
        throw DecodingError.typeMismatch(Any.self, .init(codingPath: [], debugDescription: "single-value not supported"))
    }
}

@usableFromInline
internal struct PathKeyedContainer<K: CodingKey>: KeyedDecodingContainerProtocol, Decoder {
    @usableFromInline internal let entries: [(String, String)]
    @usableFromInline internal let codingPath: [CodingKey]

    @inlinable init(entries: [(String, String)], codingPath: [CodingKey]) {
        self.entries = entries
        self.codingPath = codingPath
    }

    // ── Decoder conformance (for superDecoder) ───────────────────
    public var userInfo: [CodingUserInfoKey: Any] { [:] }
    public func container<NestedKey>(keyedBy type: NestedKey.Type) throws
        -> KeyedDecodingContainer<NestedKey> where NestedKey: CodingKey {
        KeyedDecodingContainer(PathKeyedContainer<NestedKey>(entries: entries, codingPath: codingPath))
    }
    public func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        throw DecodingError.typeMismatch(Any.self, .init(codingPath: codingPath, debugDescription: "unkeyed not supported"))
    }
    public func singleValueContainer() throws -> SingleValueDecodingContainer {
        throw DecodingError.typeMismatch(Any.self, .init(codingPath: codingPath, debugDescription: "single-value not supported"))
    }

    // ── KeyedDecodingContainerProtocol ───────────────────────────
    public var allKeys: [K] { entries.compactMap { K(stringValue: $0.0) } }
    public func contains(_ key: K) -> Bool { entries.contains { $0.0 == key.stringValue } }
    public func decodeNil(forKey key: K) -> Bool { !contains(key) }

    public func decode(_ type: String.Type, forKey key: K) throws -> String {
        for (n, v) in entries where n == key.stringValue { return v }
        throw DecodingError.keyNotFound(key, .init(codingPath: codingPath, debugDescription: "missing"))
    }
    public func decode(_ type: Int.Type, forKey key: K) throws -> Int {
        guard let s = try? decode(String.self, forKey: key), let v = Int(s) else {
            throw DecodingError.typeMismatch(Int.self, .init(codingPath: codingPath, debugDescription: "not an Int"))
        }
        return v
    }
    public func decode(_ type: Int32.Type, forKey key: K) throws -> Int32 {
        guard let s = try? decode(String.self, forKey: key), let v = Int32(s) else {
            throw DecodingError.typeMismatch(Int32.self, .init(codingPath: codingPath, debugDescription: "not an Int32"))
        }
        return v
    }
    public func decode(_ type: Int64.Type, forKey key: K) throws -> Int64 {
        guard let s = try? decode(String.self, forKey: key), let v = Int64(s) else {
            throw DecodingError.typeMismatch(Int64.self, .init(codingPath: codingPath, debugDescription: "not an Int64"))
        }
        return v
    }
    public func decode(_ type: UInt.Type, forKey key: K) throws -> UInt {
        guard let s = try? decode(String.self, forKey: key), let v = UInt(s) else {
            throw DecodingError.typeMismatch(UInt.self, .init(codingPath: codingPath, debugDescription: "not a UInt"))
        }
        return v
    }
    public func decode(_ type: UInt32.Type, forKey key: K) throws -> UInt32 {
        guard let s = try? decode(String.self, forKey: key), let v = UInt32(s) else {
            throw DecodingError.typeMismatch(UInt32.self, .init(codingPath: codingPath, debugDescription: "not a UInt32"))
        }
        return v
    }
    public func decode(_ type: UInt64.Type, forKey key: K) throws -> UInt64 {
        guard let s = try? decode(String.self, forKey: key), let v = UInt64(s) else {
            throw DecodingError.typeMismatch(UInt64.self, .init(codingPath: codingPath, debugDescription: "not a UInt64"))
        }
        return v
    }
    public func decode(_ type: Double.Type, forKey key: K) throws -> Double {
        guard let s = try? decode(String.self, forKey: key), let v = Double(s) else {
            throw DecodingError.typeMismatch(Double.self, .init(codingPath: codingPath, debugDescription: "not a Double"))
        }
        return v
    }
    public func decode(_ type: Bool.Type, forKey key: K) throws -> Bool {
        guard let s = try? decode(String.self, forKey: key), let v = Bool(s) else {
            throw DecodingError.typeMismatch(Bool.self, .init(codingPath: codingPath, debugDescription: "not a Bool"))
        }
        return v
    }
    public func decode<T: Decodable>(_ type: T.Type, forKey key: K) throws -> T {
        throw DecodingError.typeMismatch(T.self, .init(codingPath: codingPath, debugDescription: "unsupported nested type"))
    }

    public func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type, forKey key: K) throws
        -> KeyedDecodingContainer<NestedKey> where NestedKey: CodingKey {
        throw DecodingError.typeMismatch(Any.self, .init(codingPath: codingPath, debugDescription: "nested not supported"))
    }
    public func nestedUnkeyedContainer(forKey key: K) throws -> UnkeyedDecodingContainer {
        throw DecodingError.typeMismatch(Any.self, .init(codingPath: codingPath, debugDescription: "nested not supported"))
    }
    public func superDecoder() throws -> Decoder { self }
    public func superDecoder(forKey key: K) throws -> Decoder { self }
}
