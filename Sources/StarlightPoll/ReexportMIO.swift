//===----------------------------------------------------------------------===//
//
//  Reexport.swift
//  StarlightPoll
//
//  Thin re-export layer. StarlightPoll now delegates to the Pulsar
//  package (github.com/akvilary/pulsar) for the actual event loop
//  implementation. This module exists so that `import StarlightPoll`
//  continues to work across the Starlight codebase without changing
//  every import statement.
//
//===----------------------------------------------------------------------===//

#if os(Linux)

// Pulsar re-exports MIO types internally via @_exported, so this
// transitively brings in Poll, Token, Interest, Ready, Event, Events,
// Waker, Registry, PollError, PollEventLoop, PaddedAtomicInt64.
@_exported import Pulsar

#endif // os(Linux)
