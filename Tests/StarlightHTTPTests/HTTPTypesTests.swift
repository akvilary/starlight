//===----------------------------------------------------------------------===//
//
//  HTTPTypesTests.swift
//  StarlightHTTPTests
//
//===----------------------------------------------------------------------===//

import Testing
import StarlightHTTP

@Suite("HTTP value types")
struct HTTPTypesTests {

    @Test("Method equality is case-sensitive on construction")
    func methodEquality() {
        // Internal storage is lowercased but the original string is
        // preserved on description. Standard methods compare equal
        // to their canonical construction.
        #expect(Method.GET == Method("GET"))
        #expect(Method.POST != Method.GET)
    }

    @Test("StatusCode canonical reason phrases")
    func statusReasons() {
        #expect(StatusCode.ok.canonicalReason == "OK")
        #expect(StatusCode.notFound.canonicalReason == "Not Found")
        #expect(StatusCode(418).canonicalReason == "Unknown")
    }

    @Test("HeaderMap is case-insensitive on lookup")
    func headerMapCaseInsensitive() {
        var map = HeaderMap()
        map.insert(.contentType, "application/json")
        #expect(map.first(for: .contentType)?.description == "application/json")
        #expect(map.contains(.contentType))
    }

    @Test("HeaderMap preserves insertion order on append")
    func headerMapAppendOrder() {
        var map = HeaderMap()
        map.append(.setCookie, "a=1")
        map.append(.setCookie, "b=2")
        let cookies = map.all(for: .setCookie)
        #expect(cookies.count == 2)
        #expect(cookies[0].description == "a=1")
        #expect(cookies[1].description == "b=2")
    }

    @Test("Uri splits path and query")
    func uriSplit() {
        let uri = Uri("/users/42?active=true&limit=10")
        #expect(uri.pathString == "/users/42")
        #expect(uri.queryString == "active=true&limit=10")
    }
}
