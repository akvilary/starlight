//===----------------------------------------------------------------------===//
//
//  TestClient.swift
//  StarlightServer
//
//  Direct port of `axum::test::TestClient`.
//
//  In-process testing utility — calls the Service directly without
//  TCP sockets. Lets you write handler tests without binding a port.
//
//  ```swift
//  let client = TestClient(router)
//  let response = await client.get("/")
//  #expect(response.status == .ok)
//  ```
//
//===----------------------------------------------------------------------===//

import Foundation
import HTTP
import Prism

/// In-process test client. Calls a Service<Request> directly,
/// without TCP. Direct port of `axum::test::TestClient`.
public final class TestClient: Sendable {
    public let service: BoxService<HTTP.Request, HTTP.Response>

    @inlinable public init<S: Service>(_ service: S)
    where S.Request == HTTP.Request, S.Response == HTTP.Response {
        self.service = BoxService(service)
    }

    // MARK: - Convenience request builders

    /// Send a GET request to `path`.
    public func get(_ path: String, headers: HeaderMap = HeaderMap()) async throws -> HTTP.Response {
        try await request(method: .GET, path: path, headers: headers, body: .empty)
    }

    /// Send a POST request with a body.
    public func post(_ path: String, body: Body = .empty, headers: HeaderMap = HeaderMap()) async throws -> HTTP.Response {
        try await request(method: .POST, path: path, headers: headers, body: body)
    }

    /// Send a PUT request with a body.
    public func put(_ path: String, body: Body = .empty, headers: HeaderMap = HeaderMap()) async throws -> HTTP.Response {
        try await request(method: .PUT, path: path, headers: headers, body: body)
    }

    /// Send a DELETE request.
    public func delete(_ path: String, headers: HeaderMap = HeaderMap()) async throws -> HTTP.Response {
        try await request(method: .DELETE, path: path, headers: headers, body: .empty)
    }

    /// Send a PATCH request with a body.
    public func patch(_ path: String, body: Body = .empty, headers: HeaderMap = HeaderMap()) async throws -> HTTP.Response {
        try await request(method: .PATCH, path: path, headers: headers, body: body)
    }

    /// Send a request with full control over all fields.
    public func request(
        method: Method,
        path: String,
        headers: HeaderMap = HeaderMap(),
        body: Body = .empty
    ) async throws -> HTTP.Response {
        let request = HTTP.Request(
            method: method,
            uri: Uri(path),
            version: .http11,
            headers: headers,
            body: body
        )
        return try await service.call(request)
    }

    // MARK: - JSON helpers

    /// Send a POST with a JSON body.
    public func postJSON<T: Encodable>(
        _ path: String,
        _ value: T,
        headers: HeaderMap = HeaderMap()
    ) async throws -> HTTP.Response {
        let data = try JSONEncoder().encode(value)
        var hdrs = headers
        hdrs.insert(.contentType, "application/json")
        return try await post(path, body: .buffered(Array(data)), headers: hdrs)
    }
}

// MARK: - Response helpers

extension HTTP.Response {
    /// Collect the body as a UTF-8 String. Convenience for tests.
    public func bodyString() async -> String {
        let bytes = (try? await body.collect()) ?? []
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Collect the body and JSON-decode it.
    public func bodyJSON<T: Decodable>(_ type: T.Type = T.self) async throws -> T {
        let bytes = try await body.collect()
        return try JSONDecoder().decode(T.self, from: Data(bytes))
    }
}
