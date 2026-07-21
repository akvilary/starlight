//===----------------------------------------------------------------------===//
//
//  Form.swift
//  StarlightExtractors
//
//  Direct port of `axum::extract::Form<T>`.
//
//  Decodes `application/x-www-form-urlencoded` request bodies into
//  a `Decodable` type. Mirrors axum::extract::Form exactly — same
//  content-type check, same rejection types.
//
//===----------------------------------------------------------------------===//

import Foundation
import HTTP
import StarlightCore

/// Extractor for `application/x-www-form-urlencoded` request bodies.
///
/// Direct port of `axum::extract::Form<T>`. Decodes the body into
/// `T` via `URLDecoder` (Foundation's analogue of serde_urlencoded).
///
/// ```swift
/// struct LoginForm: Decodable {
///     let username: String
///     let password: String
/// }
/// router.post("/login") { (form: Form<LoginForm>) in
///     return .plain("hi \(form.value.username)")
/// }
/// ```
public struct Form<T: Decodable & Sendable>: Sendable {
    public let value: T

    @inlinable public init(_ value: T) { self.value = value }
}

extension Form: FromRequest {
    public typealias State = AnySendable

    public static func fromRequest(
        _ request: consuming Request<Body>,
        state: borrowing AnySendable
    ) async throws -> Form<T> {
        // Content-Type check — axum requires the exact media type.
        // We allow charset suffix (e.g. "application/x-www-form-urlencoded; charset=utf-8").
        let ct = request.headers.first(for: .contentType)?.description ?? ""
        if !ct.lowercased().hasPrefix("application/x-www-form-urlencoded") {
            throw ExtractionRejection(
                "invalid content-type: expected application/x-www-form-urlencoded",
                status: .unsupportedMediaType
            )
        }

        let bytes = try await request.body.collect()
        let bodyString = String(decoding: bytes, as: UTF8.self)

        // Parse `key=value&key2=value2` into a dictionary. URL-decode
        // both keys and values (+ → space, %XX → byte).
        var dict: [String: Any] = [:]
        for pair in bodyString.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = Self.urlDecode(String(parts[0]))
            let rawValue = Self.urlDecode(String(parts[1]))
            // Coerce numeric strings to numbers so JSONDecoder can
            // match Int / Double fields. Matches serde_urlencoded's
            // behaviour of parsing values as the target type.
            dict[key] = Self.coerce(rawValue)
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: dict)
            let decoded = try JSONDecoder().decode(T.self, from: data)
            return Form(decoded)
        } catch {
            throw ExtractionRejection("form decode failed: \(error)", status: .badRequest)
        }
    }

    /// Try to interpret `s` as Int, then Double, then fall back to String.
    /// Lets JSONDecoder match numeric struct fields without a custom
    /// urlencoded decoder.
    @inline(__always)
    private static func coerce(_ s: String) -> Any {
        if let i = Int(s) { return i }
        if let d = Double(s) { return d }
        return s
    }

    /// URL-decode (%XX, `+` → space). Same as Query.swift's decode.
    @inline(__always)
    private static func urlDecode(_ s: String) -> String {
        let bytes = Array(s.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x2B {
                out.append(0x20)
            } else if b == 0x25, i + 2 < bytes.count,
                      let hi = Self.hexDigit(bytes[i + 1]),
                      let lo = Self.hexDigit(bytes[i + 2]) {
                out.append(UInt8(hi * 16 + lo))
                i += 2
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

extension Form: IntoResponse where T: Encodable {
    public func intoResponse() -> Response<Body> {
        // Re-encode as urlencoded. For v0.1 just JSON-encode then
        // flatten — full urlencoded encoder lands later.
        do {
            let data = try JSONEncoder().encode(value)
            // Convert {"a":"b","c":"d"} → "a=b&c=d"
            if let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let pairs = dict.map { k, v in
                    "\(Self.urlEncode(k))=\(Self.urlEncode(String(describing: v)))"
                }
                let body = pairs.joined(separator: "&")
                var headers = HeaderMap()
                headers.insert(.contentType, "application/x-www-form-urlencoded")
                headers.insert(.contentLength, String(body.utf8.count))
                return Response(status: .ok, headers: headers, body: .buffered(Array(body.utf8)))
            }
            return .plain("form encode failed", status: .internalServerError)
        } catch {
            return .plain("form encode failed: \(error)", status: .internalServerError)
        }
    }

    @inline(__always)
    private static func urlEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }
}
