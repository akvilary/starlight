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
    /// `Path<T>` extractor. Delegates to `StringKeyedDecoder`.
    public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try StringKeyedDecoder.decode(entries, into: T.self)
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

/// Decodes `[(String, String)]` key-value pairs into a `Decodable` type.
///
/// Used by `Path<T>`, `Query<T>`, and `Form<T>` extractors — anything
/// that has flat key-value string pairs and needs to decode them into a
/// struct of primitives (Int, Double, Bool, String, etc.).
///
/// Coerces strings to numbers via `Int(String)`, `Double(String)`, etc.
/// — unlike `JSONDecoder`, which rejects JSON strings where numbers are
/// expected.
public enum StringKeyedDecoder {
    /// Decode `entries` into `T`. Throws `DecodingError` on missing keys
    /// (for non-optional fields) or type mismatches.
    public static func decode<T: Decodable>(
        _ entries: [(String, String)],
        into type: T.Type = T.self
    ) throws -> T {
        let decoder = _StringKeyedDecoderImpl(entries: entries)
        return try T(from: decoder)
    }
}

// MARK: - Internal implementation

@usableFromInline
internal struct _StringKeyedDecoderImpl: Decoder {
    @usableFromInline internal let entries: [(String, String)]

    @inlinable init(entries: [(String, String)]) { self.entries = entries }

    public var codingPath: [CodingKey] { [] }
    public var userInfo: [CodingUserInfoKey: Any] { [:] }

    public func container<Key>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key>
    where Key: CodingKey {
        KeyedDecodingContainer(_StringKeyedContainer(entries: entries, codingPath: []))
    }
    public func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        throw DecodingError.typeMismatch(Any.self, .init(codingPath: [], debugDescription: "unkeyed not supported"))
    }
    /// Top-level single-value decode — supports `Path<UUID>` / `Query<Int>`
    /// when exactly one key-value pair was captured. Mirrors axum, where
    /// `Path<Uuid>` works whenever the route captures a single parameter.
    public func singleValueContainer() throws -> SingleValueDecodingContainer {
        guard entries.count == 1 else {
            throw DecodingError.typeMismatch(
                Any.self,
                .init(codingPath: [], debugDescription:
                    "single-value decode requires exactly one key-value pair, got \(entries.count)")
            )
        }
        return _StringValueContainer(value: entries[0].1, codingPath: [])
    }
}

@usableFromInline
internal struct _StringKeyedContainer<K: CodingKey>: KeyedDecodingContainerProtocol, Decoder {
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
        KeyedDecodingContainer(_StringKeyedContainer<NestedKey>(entries: entries, codingPath: codingPath))
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
    public func decode(_ type: Int8.Type, forKey key: K) throws -> Int8 {
        guard let s = try? decode(String.self, forKey: key), let v = Int8(s) else {
            throw DecodingError.typeMismatch(Int8.self, .init(codingPath: codingPath, debugDescription: "not an Int8"))
        }
        return v
    }
    public func decode(_ type: Int16.Type, forKey key: K) throws -> Int16 {
        guard let s = try? decode(String.self, forKey: key), let v = Int16(s) else {
            throw DecodingError.typeMismatch(Int16.self, .init(codingPath: codingPath, debugDescription: "not an Int16"))
        }
        return v
    }
    public func decode(_ type: UInt8.Type, forKey key: K) throws -> UInt8 {
        guard let s = try? decode(String.self, forKey: key), let v = UInt8(s) else {
            throw DecodingError.typeMismatch(UInt8.self, .init(codingPath: codingPath, debugDescription: "not a UInt8"))
        }
        return v
    }
    public func decode(_ type: UInt16.Type, forKey key: K) throws -> UInt16 {
        guard let s = try? decode(String.self, forKey: key), let v = UInt16(s) else {
            throw DecodingError.typeMismatch(UInt16.self, .init(codingPath: codingPath, debugDescription: "not a UInt16"))
        }
        return v
    }
    public func decode(_ type: Float.Type, forKey key: K) throws -> Float {
        guard let s = try? decode(String.self, forKey: key), let v = Float(s) else {
            throw DecodingError.typeMismatch(Float.self, .init(codingPath: codingPath, debugDescription: "not a Float"))
        }
        return v
    }
    /// Generic decode — supports any `Decodable` that reads from a
    /// single-value string container (`UUID`, `Date`, …) or from an
    /// unkeyed container over the repeated values of the key
    /// (`[String]`, `[UUID]`, … for `?tags=a&tags=b`).
    public func decode<T: Decodable>(_ type: T.Type, forKey key: K) throws -> T {
        var values: [String] = []
        for (n, v) in entries where n == key.stringValue { values.append(v) }
        guard let first = values.first else {
            throw DecodingError.keyNotFound(key, .init(codingPath: codingPath, debugDescription: "missing"))
        }
        // `values` is non-empty; the decoder reads the first value via
        // `singleValueContainer()` and all of them via `unkeyedContainer()`.
        return try T(from: _StringFieldDecoder(values: values, codingPath: codingPath + [key]))
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

// MARK: - Field decoder (single value + repeated values)

/// Decoder over the string value(s) captured for one key. Enables the
/// generic `decode<T>(forKey:)` path in `StringKeyedDecoder`:
///
/// • `singleValueContainer()` — over the first value. Types that decode
///   from a single string (`UUID`, `Date` via custom strategy, …) work.
/// • `unkeyedContainer()` — over ALL values of the key, so repeated
///   query keys (`?tags=a&tags=b`) decode into arrays (`[String]`,
///   `[UUID]`, …).
/// • `container(keyedBy:)` — unsupported (flat key-value model).
@usableFromInline
internal struct _StringFieldDecoder: Decoder {
    @usableFromInline internal let values: [String]
    @usableFromInline internal let codingPath: [CodingKey]

    @inlinable
    init(values: [String], codingPath: [CodingKey] = []) {
        self.values = values
        self.codingPath = codingPath
    }

    public var userInfo: [CodingUserInfoKey: Any] { [:] }

    public func container<NestedKey>(keyedBy type: NestedKey.Type) throws
        -> KeyedDecodingContainer<NestedKey> where NestedKey: CodingKey {
        throw DecodingError.typeMismatch(
            Any.self,
            .init(codingPath: codingPath, debugDescription: "nested keyed containers not supported by StringKeyedDecoder")
        )
    }

    public func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        _StringValuesUnkeyedContainer(values: values, codingPath: codingPath)
    }

    public func singleValueContainer() throws -> SingleValueDecodingContainer {
        _StringValueContainer(value: values.first ?? "", codingPath: codingPath)
    }
}

/// Single-value container over one string — the shared coercion point
/// for every primitive type.
@usableFromInline
internal struct _StringValueContainer: SingleValueDecodingContainer {
    @usableFromInline internal let value: String
    @usableFromInline internal let codingPath: [CodingKey]

    @inlinable
    init(value: String, codingPath: [CodingKey]) {
        self.value = value
        self.codingPath = codingPath
    }

    public func decodeNil() -> Bool { false }

    public func decode(_ type: String.Type) throws -> String { value }

    public func decode(_ type: Int.Type) throws -> Int {
        guard let v = Int(value) else { throw mismatch(Int.self) }
        return v
    }
    public func decode(_ type: Int8.Type) throws -> Int8 {
        guard let v = Int8(value) else { throw mismatch(Int8.self) }
        return v
    }
    public func decode(_ type: Int16.Type) throws -> Int16 {
        guard let v = Int16(value) else { throw mismatch(Int16.self) }
        return v
    }
    public func decode(_ type: Int32.Type) throws -> Int32 {
        guard let v = Int32(value) else { throw mismatch(Int32.self) }
        return v
    }
    public func decode(_ type: Int64.Type) throws -> Int64 {
        guard let v = Int64(value) else { throw mismatch(Int64.self) }
        return v
    }
    public func decode(_ type: UInt.Type) throws -> UInt {
        guard let v = UInt(value) else { throw mismatch(UInt.self) }
        return v
    }
    public func decode(_ type: UInt8.Type) throws -> UInt8 {
        guard let v = UInt8(value) else { throw mismatch(UInt8.self) }
        return v
    }
    public func decode(_ type: UInt16.Type) throws -> UInt16 {
        guard let v = UInt16(value) else { throw mismatch(UInt16.self) }
        return v
    }
    public func decode(_ type: UInt32.Type) throws -> UInt32 {
        guard let v = UInt32(value) else { throw mismatch(UInt32.self) }
        return v
    }
    public func decode(_ type: UInt64.Type) throws -> UInt64 {
        guard let v = UInt64(value) else { throw mismatch(UInt64.self) }
        return v
    }
    public func decode(_ type: Float.Type) throws -> Float {
        guard let v = Float(value) else { throw mismatch(Float.self) }
        return v
    }
    public func decode(_ type: Double.Type) throws -> Double {
        guard let v = Double(value) else { throw mismatch(Double.self) }
        return v
    }
    public func decode(_ type: Bool.Type) throws -> Bool {
        guard let v = Bool(value) else { throw mismatch(Bool.self) }
        return v
    }
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try T(from: _StringFieldDecoder(values: [value], codingPath: codingPath))
    }

    @inline(__always)
    private func mismatch(_ type: Any.Type) -> DecodingError {
        .typeMismatch(type, .init(codingPath: codingPath, debugDescription: "cannot coerce \"\(value)\""))
    }
}

/// Unkeyed container over the repeated values of one key — the
/// multi-value query support (`?tags=a&tags=b` → `tags: [String]`).
@usableFromInline
internal struct _StringValuesUnkeyedContainer: UnkeyedDecodingContainer {
    @usableFromInline internal let values: [String]
    @usableFromInline internal let codingPath: [CodingKey]
    @usableFromInline internal var currentIndex: Int = 0

    @inlinable
    init(values: [String], codingPath: [CodingKey]) {
        self.values = values
        self.codingPath = codingPath
    }

    public var count: Int? { values.count }
    public var isAtEnd: Bool { currentIndex >= values.count }

    public mutating func decodeNil() throws -> Bool {
        // A flat string model has no null elements — consume one slot
        // and report non-nil, matching JSON's `[null]` semantics.
        advance()
        return false
    }

    public mutating func decode(_ type: String.Type) throws -> String { try next { try $0.decode(String.self) } }
    public mutating func decode(_ type: Int.Type) throws -> Int { try next { try $0.decode(Int.self) } }
    public mutating func decode(_ type: Int8.Type) throws -> Int8 { try next { try $0.decode(Int8.self) } }
    public mutating func decode(_ type: Int16.Type) throws -> Int16 { try next { try $0.decode(Int16.self) } }
    public mutating func decode(_ type: Int32.Type) throws -> Int32 { try next { try $0.decode(Int32.self) } }
    public mutating func decode(_ type: Int64.Type) throws -> Int64 { try next { try $0.decode(Int64.self) } }
    public mutating func decode(_ type: UInt.Type) throws -> UInt { try next { try $0.decode(UInt.self) } }
    public mutating func decode(_ type: UInt8.Type) throws -> UInt8 { try next { try $0.decode(UInt8.self) } }
    public mutating func decode(_ type: UInt16.Type) throws -> UInt16 { try next { try $0.decode(UInt16.self) } }
    public mutating func decode(_ type: UInt32.Type) throws -> UInt32 { try next { try $0.decode(UInt32.self) } }
    public mutating func decode(_ type: UInt64.Type) throws -> UInt64 { try next { try $0.decode(UInt64.self) } }
    public mutating func decode(_ type: Float.Type) throws -> Float { try next { try $0.decode(Float.self) } }
    public mutating func decode(_ type: Double.Type) throws -> Double { try next { try $0.decode(Double.self) } }
    public mutating func decode(_ type: Bool.Type) throws -> Bool { try next { try $0.decode(Bool.self) } }

    public mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let path = codingPath
        return try next { c in try T(from: _StringFieldDecoder(values: [c.value], codingPath: path)) }
    }

    public mutating func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type) throws
        -> KeyedDecodingContainer<NestedKey> where NestedKey: CodingKey {
        throw DecodingError.typeMismatch(
            Any.self,
            .init(codingPath: codingPath, debugDescription: "nested containers not supported by StringKeyedDecoder")
        )
    }
    public mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        throw DecodingError.typeMismatch(
            Any.self,
            .init(codingPath: codingPath, debugDescription: "nested containers not supported by StringKeyedDecoder")
        )
    }
    public mutating func superDecoder() throws -> Decoder {
        _StringFieldDecoder(values: values, codingPath: codingPath)
    }

    @inline(__always)
    private mutating func advance() {
        currentIndex += 1
    }

    @inline(__always)
    private mutating func next<T>(_ decode: (_StringValueContainer) throws -> T) throws -> T {
        guard !isAtEnd else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: codingPath, debugDescription: "unkeyed container is at end")
            )
        }
        let container = _StringValueContainer(value: values[currentIndex], codingPath: codingPath)
        advance()
        return try decode(container)
    }
}
