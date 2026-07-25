//===----------------------------------------------------------------------===//
//
//  ReexportMIO.swift
//  StarlightPoll
//
//  Dedicated file for `@_exported import MIO`. Kept separate from
//  `PollEventLoop.swift` because `@_exported import` combined with
//  `~Copyable` type extension visibility is fragile in current Swift
//  6.2 toolchains: when the same source file both re-exports a module
//  and calls methods on its `~Copyable` types, the methods silently
//  disappear from the type checker's view. Isolating the re-export
//  to its own file sidesteps the issue.
//
//===----------------------------------------------------------------------===//

#if os(Linux)

// Consumers of `import StarlightPoll` get `Poll`, `Token`, `Interest`,
// `Ready`, `Event`, `Events`, `Waker`, `Registry`, `PollError`
// transitively through this re-export.
@_exported import MIO

#endif // os(Linux)
