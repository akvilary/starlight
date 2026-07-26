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
import Prism

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
///
/// **Security:** Path traversal is prevented via `realpath(3)`
/// canonicalization + prefix verification. The resolved path must
/// start with the canonical root directory. Symlinks are followed
/// by `realpath` — a symlink inside root that points outside will
/// resolve to the outside path and fail the prefix check.
public struct ServeDir: Service, Sendable {
    public typealias Request = HTTP.Request
    public typealias Response = HTTP.Response

    public let root: String
    public let maxFileSize: Int

    /// Canonicalized root path, resolved once at init. All served
    /// files must resolve to a path starting with this prefix.
    private let canonicalRoot: String

    public init(root: String, maxFileSize: Int = 10 * 1024 * 1024) {
        self.root = root
        self.maxFileSize = maxFileSize
        #if canImport(Glibc)
        self.canonicalRoot = Self.resolvePath(root) ?? root
        #else
        self.canonicalRoot = root
        #endif
    }

    public func call(_ request: consuming HTTP.Request) async throws -> HTTP.Response {
        #if canImport(Glibc)
        let rawPath = request.uri.pathString

        // 1. Percent-decode the URL path. Path components do NOT
        //    treat '+' as space (unlike query strings).
        let decodedPath = Self.percentDecode(rawPath)

        // 2. Reject null bytes — defense against C-string truncation
        //    attacks (e.g. /etc/passwd\0.txt).
        guard !decodedPath.contains("\0") else {
            return errorResponse(.badRequest, "null byte in path")
        }

        // 3. Join root + decoded relative path.
        let relativePath = decodedPath.hasPrefix("/")
            ? String(decodedPath.dropFirst())
            : decodedPath
        let fullPath = root + "/" + relativePath

        // 4. Canonicalize via realpath — resolves ALL ".." components
        //    and symlinks. Returns nil if the file doesn't exist.
        guard let resolved = Self.resolvePath(fullPath) else {
            return errorResponse(.notFound, "Not Found")
        }

        // 5. Verify the resolved path is inside canonicalRoot.
        //    This is the chroot-style check that defeats all traversal
        //    attacks — realpath already resolved everything.
        guard resolved == canonicalRoot
              || resolved.hasPrefix(canonicalRoot + "/") else {
            return errorResponse(.forbidden, "Forbidden")
        }

        // 6. stat to determine file vs directory. Use lstat to avoid
        //    name conflict with the `stat` struct type in Swift's
        //    Glibc module. Since realpath already resolved symlinks,
        //    lstat and stat give identical results here.
        var st = stat()
        let statRc = resolved.withCString { p in
            Glibc.lstat(p, &st)
        }
        guard statRc == 0 else {
            return errorResponse(.notFound, "Not Found")
        }

        // 7. If directory → try index.html (with its own realpath check).
        if (st.st_mode & S_IFMT) == S_IFDIR {
            let indexResolved = Self.resolvePath(resolved + "/index.html")
            guard let indexResolved,
                  indexResolved.hasPrefix(canonicalRoot + "/") else {
                return errorResponse(.notFound, "Not Found")
            }
            // Re-stat index.html for size + mtime.
            var indexSt = stat()
            let indexStatRc = indexResolved.withCString { p in
                Glibc.lstat(p, &indexSt)
            }
            guard indexStatRc == 0 else {
                return errorResponse(.notFound, "Not Found")
            }
            return serveFile(path: indexResolved, st: indexSt)
        }

        // 8. Regular file — serve it.
        return serveFile(path: resolved, st: st)
        #else
        return errorResponse(.notFound, "Static files require Linux")
        #endif
    }

    // MARK: - Internals

    #if canImport(Glibc)
    /// Resolve a path to its canonical absolute form via `realpath(3)`.
    /// Returns nil if the path doesn't exist or can't be resolved.
    @usableFromInline
    internal static func resolvePath(_ path: String) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)  // PATH_MAX
        let result = path.withCString { p in
            buf.withUnsafeMutableBufferPointer { b in
                Glibc.realpath(p, b.baseAddress)
            }
        }
        guard let r = result else { return nil }
        return String(cString: r)
    }

    /// Percent-decode a URL path component. `%XX` → byte.
    /// `+` is NOT decoded as space (path component semantics per
    /// RFC 3986 — only query strings treat `+` as space).
    @usableFromInline
    internal static func percentDecode(_ string: String) -> String {
        let bytes = Array(string.utf8)
        if !bytes.contains(0x25) {  // fast path: no '%'
            return string
        }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x25,               // '%'
               i + 2 < bytes.count,
               let hi = hexDigit(bytes[i + 1]),
               let lo = hexDigit(bytes[i + 2]) {
                out.append(hi << 4 | lo)
                i += 3
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    @usableFromInline
    internal static func hexDigit(_ b: UInt8) -> UInt8? {
        switch b {
        case 0x30...0x39: return b - 0x30       // 0-9
        case 0x41...0x46: return b - 0x41 + 10  // A-F
        case 0x61...0x66: return b - 0x61 + 10  // a-f
        default: return nil
        }
    }

    private func serveFile(path: String, st: stat) -> HTTP.Response {
        let size = Int(st.st_size)

        // Security: don't serve files larger than maxFileSize.
        guard size <= maxFileSize else {
            return errorResponse(.payloadTooLarge, "File too large")
        }

        // Open and read. Use the canonical path (already verified).
        let fd = Glibc.open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            return errorResponse(.notFound, "Not Found")
        }
        defer { _ = Glibc.close(fd) }

        // Read file into buffer. Loop for special files (/proc, etc.)
        // that may return fewer bytes than st_size in one read.
        var bytes = [UInt8](repeating: 0, count: size)
        var bytesRead = 0
        while bytesRead < size {
            let n = bytes.withUnsafeMutableBufferPointer { ptr in
                Glibc.read(fd, ptr.baseAddress!.advanced(by: bytesRead), size - bytesRead)
            }
            if n <= 0 { break }
            bytesRead += n
        }
        guard bytesRead == size else {
            return errorResponse(.internalServerError, "read failed")
        }

        // Build response headers.
        var headers = HeaderMap()
        headers.insert(.contentType, MimeType.for(path))
        headers.insert(.contentLength, String(size))

        // ETag from mtime + size.
        let etag = "\"\(st.st_mtim.tv_sec)-\(size)\""
        headers.insert(.etag, etag)

        return HTTP.Response(
            status: .ok,
            headers: headers,
            body: .buffered(bytes)
        )
    }
    #endif

    @inline(__always)
    private func errorResponse(_ status: StatusCode, _ message: String) -> HTTP.Response {
        var headers = HeaderMap()
        headers.insert(.contentType, "text/plain; charset=utf-8")
        headers.insert(.contentLength, String(message.utf8.count))
        return HTTP.Response(status: status, headers: headers, body: .buffered(Array(message.utf8)))
    }
}

extension HeaderName {
    /// `ETag`
    public static let etag = HeaderName("etag")
}
