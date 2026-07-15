//===----------------------------------------------------------------------===//
//
//  IORingBox.swift
//  StarlightIORing
//
//  Wraps the ~Copyable IORing in a Copyable class so it can be stored
//  as an Optional and created lazily on the loop thread (SINGLE_ISSUER).
//
//===----------------------------------------------------------------------===//

import SystemPackage

final class IORingBox: @unchecked Sendable {
    var ring: IORing

    init(queueDepth: UInt32, flags: IORing.SetupFlags) throws {
        self.ring = try IORing(queueDepth: queueDepth, flags: flags)
    }
}
