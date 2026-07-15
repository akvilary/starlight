//===----------------------------------------------------------------------===//
//
//  IORingError.swift
//  StarlightIORing
//
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public struct IORingError: Error, CustomStringConvertible {
    public let code: Int32
    public let function: String
    public var description: String {
        "IORingError(\(function)): \(String(cString: strerror(code))) [\(code)]"
    }

    public init(code: Int32, function: String) {
        self.code = code
        self.function = function
    }
}
