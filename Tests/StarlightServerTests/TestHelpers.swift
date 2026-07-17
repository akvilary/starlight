//===----------------------------------------------------------------------===//
//
//  TestHelpers.swift
//  StarlightServerTests
//
//  Test-only helpers that adapt the production codec API to the
//  shape the tests were written against before A-8 (when `tryParse()`
//  was async and returned `HTTPResponse?`). The new `tryParse()` is
//  sync and returns a `ParseResult` enum — closer to how the
//  production backends actually drive the codec, but verbose in
//  tests that just want "give me the next response."
//
//===----------------------------------------------------------------------===//

import Testing
import StarlightHTTP
@testable import StarlightServer

extension HTTP1Codec {
    /// Test-only convenience: drive the codec through one parse +
    /// dispatch cycle, returning the resulting response or `nil` if
    /// the accumulator doesn't yet hold a complete request.
    ///
    /// Mirrors the pre-A-8 async `tryParse()` signature so existing
    /// tests don't have to spell out the `switch` + `await
    /// dispatchAsync()` dance on every call site.
    ///
    /// `mutating` because the underlying `tryParse()` /
    /// `dispatchAsync()` mutate the codec's parser and accumulator.
    mutating func parseAndDispatch() async -> HTTPResponse? {
        switch self.tryParse() {
        case .incomplete:
            return nil
        case .response(let r):
            return r
        case .needsAsync:
            return await self.dispatchAsync()
        }
    }
}
