//===----------------------------------------------------------------------===//
//
//  Compression.swift
//  StarlightMiddleware
//
//  Direct port of `tower_http::compression::CompressionLayer`.
//
//  Compresses response bodies using gzip. Auto-selects based on
//  Accept-Encoding header. Skips bodies < 256 bytes.
//
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
import CLinuxExt
#endif

import Foundation
import HTTP
import StarlightCore
import Prism

/// Configuration for `CompressionLayer`.
public struct CompressionConfig: Sendable {
    /// Minimum body size to compress. Bodies smaller than this are
    /// passed through uncompressed (overhead > benefit).
    public var minBodySize: Int = 256
    /// Compression level (1=fastest, 9=best, 6=default).
    public var level: Int = 6

    @inlinable public init() {}
}

/// Gzip compression middleware layer.
///
/// Direct port of `tower_http::compression::CompressionLayer`.
/// Compresses `.buffered` response bodies using gzip when:
///   1. Client sends `Accept-Encoding: gzip`
///   2. Response body is `.buffered` (not `.stream` or `.empty`)
///   3. Body size > `minBodySize`
///
/// ```swift
/// let app = ServiceBuilder()
///     .layer(CompressionLayer().asLayer())
///     .service(router)
/// ```
public struct CompressionLayer: Sendable {
    public let config: CompressionConfig

    @inlinable public init(config: CompressionConfig = CompressionConfig()) {
        self.config = config
    }

    public func asLayer() -> Layer<HTTP.Request, HTTP.Response> {
        let cfg = config
        return Layer { inner in
            BoxService { request in
                let response = try await inner.call(request)
                return Self.compress(response, request: request, config: cfg)
            }
        }
    }

    @inline(__always)
    private static func compress(
        _ response: HTTP.Response,
        request: HTTP.Request,
        config: CompressionConfig
    ) -> HTTP.Response {
        // Only compress buffered bodies above the minimum size.
        guard case .buffered(let bytes) = response.body,
              bytes.count >= config.minBodySize else {
            return response
        }

        // Check Accept-Encoding header.
        let acceptEncoding = request.headers.first(for: .acceptEncoding)?.description ?? ""
        guard acceptEncoding.lowercased().contains("gzip") else {
            return response
        }

        #if canImport(Glibc)
        // Compress using zlib gzip.
        let inputLen = bytes.count
        // Output buffer size: zlib's deflateBound formula for gzip
        // format with default parameters (windowBits=31, memLevel=8).
        // Matches zlib source: sourceLen + (sourceLen >> 12) +
        // (sourceLen >> 14) + (sourceLen >> 25) + 25.
        // The old `inputLen + 64` was insufficient for large
        // incompressible inputs (e.g. 1MB → Z_BUF_ERROR → silent
        // fallback to uncompressed).
        let outputLen = inputLen + (inputLen >> 12) + (inputLen >> 14)
                      + (inputLen >> 25) + 25
        var output = [UInt8](repeating: 0, count: outputLen)

        let compressed = bytes.withUnsafeBufferPointer { inputPtr in
            output.withUnsafeMutableBufferPointer { outputPtr in
                sl_gzip_compress(
                    inputPtr.baseAddress!, inputLen,
                    outputPtr.baseAddress!, outputLen,
                    Int32(config.level)
                )
            }
        }

        guard compressed > 0 else { return response }

        // Truncate output to actual compressed size.
        output.removeLast(output.count - Int(compressed))

        // Build compressed response.
        var headers = response.headers
        headers.insert(.contentEncoding, "gzip")
        headers.insert(.contentLength, String(compressed))
        headers.append(.vary, "Accept-Encoding")

        return HTTP.Response(
            status: response.status,
            headers: headers,
            body: .buffered(output)
        )
        #else
        return response
        #endif
    }
}

extension HeaderName {
    /// `Content-Encoding`
    public static let contentEncoding = HeaderName("content-encoding")
    /// `Vary`
    public static let vary = HeaderName("vary")
    /// `Accept-Encoding`
    public static let acceptEncoding = HeaderName("accept-encoding")
}
