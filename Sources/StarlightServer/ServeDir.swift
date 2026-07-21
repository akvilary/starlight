//===----------------------------------------------------------------------===//
//
//  ServeDir.swift
//  StarlightServer
//
//  Direct port of `tower_http::services::ServeDir`.
//
//  Serves static files from a filesystem directory. Maps URL paths
//  to filesystem paths, detects MIME types, generates ETags from
//  file modification time.
//
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
import CLinuxExt
#endif

import Foundation
import HTTP
import StarlightTower

/// MIME type detection from file extension.
public enum MimeType {
    @usableFromInline static let map: [String: String] = [
        ".html": "text/html; charset=utf-8",
        ".htm":  "text/html; charset=utf-8",
        ".css":  "text/css; charset=utf-8",
        ".js":   "application/javascript; charset=utf-8",
        ".mjs":  "application/javascript; charset=utf-8",
        ".json": "application/json; charset=utf-8",
        ".xml":  "application/xml; charset=utf-8",
        ".txt":  "text/plain; charset=utf-8",
        ".md":   "text/markdown; charset=utf-8",
        ".png":  "image/png",
        ".jpg":  "image/jpeg",
        ".jpeg": "image/jpeg",
        ".gif":  "image/gif",
        ".svg":  "image/svg+xml",
        ".ico":  "image/x-icon",
        ".webp": "image/webp",
        ".woff": "font/woff",
        ".woff2": "font/woff2",
        ".ttf":  "font/ttf",
        ".otf":  "font/otf",
        ".pdf":  "application/pdf",
        ".zip":  "application/zip",
        ".gz":   "application/gzip",
        ".tar":  "application/x-tar",
        ".mp4":  "video/mp4",
        ".webm": "video/webm",
        ".mp3":  "audio/mpeg",
        ".ogg":  "audio/ogg",
        ".wasm": "application/wasm",
        ".csv":  "text/csv; charset=utf-8",
    ]

    public static func `for`(_ path: String) -> String {
        if let dot = path.lastIndex(of: ".") {
            let ext = String(path[dot...]).lowercased()
            return map[ext] ?? "application/octet-stream"
        }
        return "application/octet-stream"
    }
}

/// Service that serves static files from a directory.
///
/// Direct port of `tower_http::services::ServeDir`.
///
/// ```swift
/// let app = Router(state: NoState())
///     .get("/*path", ServeDir(root: "./public").erase())
/// ```
public struct ServeDir: Service, Sendable {
    public typealias Request = HTTP.Request<Body>
    public typealias Response = HTTP.Response<Body>

    public let root: String
    public let maxFileSize: Int

    @inlinable public init(root: String, maxFileSize: Int = 10 * 1024 * 1024) {
        self.root = root
        self.maxFileSize = maxFileSize
    }

    public func call(_ request: consuming HTTP.Request<Body>) async throws -> HTTP.Response<Body> {
        #if canImport(Glibc)
        let requestPath = request.uri.pathString

        // Security: prevent path traversal (../../etc/passwd)
        guard !requestPath.contains("..") else {
            return errorResponse(.forbidden, "Forbidden")
        }

        // Map URL path to filesystem path
        let filePath = root + (requestPath.hasPrefix("/") ? requestPath : "/" + requestPath)

        // Try to open the file
        let fd = Glibc.open(filePath, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            // Try index.html for directory paths
            let indexPath = filePath.hasSuffix("/") ? filePath + "index.html" : filePath + "/index.html"
            let indexFd = Glibc.open(indexPath, O_RDONLY | O_CLOEXEC)
            guard indexFd >= 0 else {
                return errorResponse(.notFound, "Not Found")
            }
            defer { _ = Glibc.close(indexFd) }
            return serveFile(fd: indexFd, path: indexPath)
        }
        defer { _ = Glibc.close(fd) }
        return serveFile(fd: fd, path: filePath)
        #else
        return errorResponse(.notFound, "Static files require Linux")
        #endif
    }

    #if canImport(Glibc)
    private func serveFile(fd: CInt, path: String) -> HTTP.Response<Body> {
        // Get file stat for size + mtime
        var st = stat()
        guard Glibc.fstat(fd, &st) == 0 else {
            return errorResponse(.internalServerError, "fstat failed")
        }
        let size = Int(st.st_size)

        // Security: don't serve files larger than maxFileSize
        guard size <= maxFileSize else {
            return errorResponse(.payloadTooLarge, "File too large")
        }

        // Read file into buffer
        var bytes = [UInt8](repeating: 0, count: size)
        let n = bytes.withUnsafeMutableBufferPointer { ptr in
            Glibc.read(fd, ptr.baseAddress, size)
        }
        guard n == size else {
            return errorResponse(.internalServerError, "read failed")
        }

        // Build response headers
        var headers = HeaderMap()
        headers.insert(.contentType, MimeType.for(path))
        headers.insert(.contentLength, String(size))

        // ETag from mtime + size
        let etag = "\"\(st.st_mtim.tv_sec)-\(size)\""
        headers.insert(.etag, etag)

        return HTTP.Response<Body>(
            status: .ok,
            headers: headers,
            body: .buffered(bytes)
        )
    }
    #endif

    @inline(__always)
    private func errorResponse(_ status: StatusCode, _ message: String) -> HTTP.Response<Body> {
        var headers = HeaderMap()
        headers.insert(.contentType, "text/plain; charset=utf-8")
        headers.insert(.contentLength, String(message.utf8.count))
        return HTTP.Response<Body>(status: status, headers: headers, body: .buffered(Array(message.utf8)))
    }
}

extension HeaderName {
    /// `ETag`
    public static let etag = HeaderName("etag")
}
