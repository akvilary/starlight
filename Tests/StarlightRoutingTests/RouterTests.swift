//===----------------------------------------------------------------------===//
//
//  RouterTests.swift
//  StarlightRoutingTests
//
//===----------------------------------------------------------------------===//

import Testing
import StarlightHTTP
@testable import StarlightRouting

@Suite("Router (Phase 0 placeholder)")
struct RouterTests {
    @Test func dispatchesToHandler() async {
        let router = Router<String> { method, path in
            return "\(method) \(path)"
        }
        let result = await router.dispatch(method: .GET, path: "/hello")
        // Note: HTTPMethod placeholder defaults to .other, so the rendering
        // will reflect that until Phase 2's parser populates the real case.
        #expect(result.contains("/hello"))
    }
}
