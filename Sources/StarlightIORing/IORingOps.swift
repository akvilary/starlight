//===----------------------------------------------------------------------===//
//
//  IORingOps.swift
//  StarlightIORing
//
//  user_data packing for io_uring SQE/CQE. Packs (channelId, op)
//  into a UInt64 — 32 bits for channelId, 32 bits for op type.
//
//===----------------------------------------------------------------------===//

/// io_uring operation type encoded in `user_data`.
internal enum IouringOp: UInt64 {
    case wakeup = 0
    case recv   = 1
    case send   = 2
}

@inline(__always)
internal func packUserData(channelId: UInt32, op: IouringOp) -> UInt64 {
    UInt64(channelId) | (op.rawValue << 32)
}

@inline(__always)
internal func unpackChannelId(_ data: UInt64) -> UInt32 {
    UInt32(truncatingIfNeeded: data)
}

@inline(__always)
internal func unpackOp(_ data: UInt64) -> IouringOp {
    IouringOp(rawValue: data >> 32) ?? .wakeup
}
