//===----------------------------------------------------------------------===//
//
//  JsonConfig.swift
//  StarlightExtractors
//
//  Shared, configurable JSON coders for `Json<T>` (and any other
//  JSON-based extractor/response type).
//
//  Two configuration points, mirroring how mature frameworks solve
//  this (Vapor `ContentConfiguration`, Hummingbird app-level coders):
//
//  1. **Process-wide default** — `JsonConfig.setDefault(...)`, called
//     once at application startup. Used by BOTH the request side
//     (decode) and the response side (encode). The response side
//     needs it because `IntoResponse.intoResponse()` has no request
//     context to read an extension from — the same constraint axum's
//     `Json` has. The registered coders are shared singletons:
//     zero per-request allocation (fixes the per-call
//     `JSONDecoder()`/`JSONEncoder()` construction).
//
//  2. **Per-request override** — `JsonConfig.layer(config)` inserts
//     the config into `Request.extensions` (the `DefaultBodyLimit`
//     pattern). Request-side decoding reads it first, so routes can
//     override date strategies or key policies per subtree.
//
//  Contract: a `JsonConfig` (and the coders it holds) must not be
//  mutated after it is registered / applied — coders are configured
//  at construction time and then used concurrently.
//
//===----------------------------------------------------------------------===//

import Foundation
import HTTPModel
import HTTPPrism
import StarlightCore

/// A configured pair of JSON coder instances.
///
/// Create one at startup, configure the date strategies / keys /
/// userInfo once, then register it:
///
/// ```swift
/// var encoder = JSONEncoder()
/// encoder.dateEncodingStrategy = .iso8601
/// var decoder = JSONDecoder()
/// decoder.dateDecodingStrategy = .iso8601
/// JsonConfig.setDefault(JsonConfig(encoder: encoder, decoder: decoder))
/// ```
public struct JsonConfig: Sendable {
    public let encoder: JSONEncoder
    public let decoder: JSONDecoder

    public init(encoder: JSONEncoder, decoder: JSONDecoder) {
        self.encoder = encoder
        self.decoder = decoder
    }

    /// Config with `.iso8601` date strategies on both coders.
    public static func iso8601() -> JsonConfig {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return JsonConfig(encoder: encoder, decoder: decoder)
    }
}

// MARK: - Process-wide registry

extension JsonConfig {

    /// The process-wide default config. Lazily falls back to a shared
    /// `JSONEncoder()`/`JSONDecoder()` pair when nothing was registered,
    /// so plain `Json<T>` usage keeps working (and stays allocation-free:
    /// the fallback pair is created once).
    public static var `default`: JsonConfig {
        _registry.get()
    }

    /// Register the process-wide default. Call once at application
    /// startup, before the server starts serving requests. Calling it
    /// again replaces the previous config (last write wins) — intended
    /// for startup and tests, not for live reconfiguration.
    public static func setDefault(_ config: JsonConfig) {
        _registry.set(config)
    }

    /// Reset the registry to the built-in fallback. Test helper.
    public static func resetDefault() {
        _registry.set(nil)
    }

    private static let _registry = _JsonConfigRegistry()

    /// Resolve the effective config for a request: the extension
    /// override if present, otherwise the process-wide default.
    public static func resolve(from extensions: Extensions) -> JsonConfig {
        extensions.get(JsonConfig.self) ?? _registry.get()
    }
}

/// NSLock-guarded holder. `get()` is on the hot path for every JSON
/// body decode — the lock is uncontended in practice (written once at
/// startup), and the fallback config is a pre-built `let`.
private final class _JsonConfigRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: JsonConfig?
    private static let fallback = JsonConfig(encoder: JSONEncoder(), decoder: JSONDecoder())

    func get() -> JsonConfig {
        lock.lock()
        defer { lock.unlock() }
        return stored ?? Self.fallback
    }

    func set(_ config: JsonConfig?) {
        lock.lock()
        defer { lock.unlock() }
        stored = config
    }
}

// MARK: - Layer (per-request override, request side only)

extension JsonConfig {

    /// Layer that inserts this config into `Request.extensions`, so
    /// request-side JSON decoding inside the wrapped subtree uses it.
    ///
    /// Note: response encoding has no request context (see type
    /// discussion) — it always uses `JsonConfig.default`.
    public static func layer(_ config: JsonConfig) -> Layer<HTTPModel.Request, HTTPModel.Response> {
        let c = config
        return Layer { inner in
            BoxService { request in
                var req = request
                req.extensions.insert(c)
                return try await inner.call(req)
            }
        }
    }
}
