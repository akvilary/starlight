//===----------------------------------------------------------------------===//
//
//  Signal.swift
//  StarlightServer
//
//  Signal-handler helpers for graceful shutdown. Async-signal-safe:
//  the kernel-level handler does nothing but flip an atomic flag,
//  then a Swift Task polls the flag and resumes the continuation.
//
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#endif

import Foundation
import Synchronization

/// Global atomic flag set by the SIGINT / SIGTERM handlers.
/// Async-signal-safe: only `Atomic.store` is called from the signal
/// handler, which is lock-free and signal-safe on all our targets.
private let shutdownFlag = Atomic<Bool>(false)

#if canImport(Glibc)
@_cdecl("starlight_signal_handler")
private func starlightSignalHandler(_ signal: Int32) {
    shutdownFlag.store(true, ordering: .releasing)
}
#endif

/// Install SIGINT + SIGTERM handlers that flip the shutdown flag.
/// Safe to call multiple times — subsequent installs replace prior
/// handlers.
public func installShutdownSignalHandlers() {
    #if canImport(Glibc)
    signal(SIGINT, starlightSignalHandler)
    signal(SIGTERM, starlightSignalHandler)
    #endif
}

/// Async function that returns when SIGINT or SIGTERM is received.
/// Polls the global atomic flag every 50ms. Cheap: each poll is
/// one relaxed atomic load + one Task.sleep continuation.
///
/// Usage:
///
/// ```swift
/// installShutdownSignalHandlers()
/// try await serve(router, port: 8080) {
///     await waitForShutdownSignal()
/// }
/// ```
public func waitForShutdownSignal() async {
    while !shutdownFlag.load(ordering: .acquiring) {
        try? await Task.sleep(for: .milliseconds(50))
    }
}
