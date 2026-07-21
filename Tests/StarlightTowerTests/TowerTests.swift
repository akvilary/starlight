//===----------------------------------------------------------------------===//
//
//  TowerTests.swift
//  StarlightTowerTests
//
//===----------------------------------------------------------------------===//

import Testing
import StarlightTower

@Suite("BoxService")
struct TowerTests {

    struct EchoService: Service {
        typealias Request = Int
        typealias Response = Int

        func call(_ request: consuming Int) async throws -> Int {
            request
        }
    }

    @Test("BoxService wraps and dispatches a concrete Service")
    func boxServiceDispatch() async throws {
        let boxed = BoxService<Int, Int>(EchoService())
        let result = try await boxed.call(42)
        #expect(result == 42)
    }
}
