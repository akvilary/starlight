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
import CLinuxExt
#endif

import Foundation
import Synchronization

/// Global atomic flag set by the SIGINT / SIGTERM handlers.
/// Async-signal-safe: only `Atomic.store` is called from the signal
/// handler, which is lock-free and signal-safe on all our targets.
private let shutdownFlag = Atomic<Bool>(false)

/// Install SIGINT + SIGTERM handlers that flip the shutdown flag.
/// Uses `sigaction` with `SA_RESTART` (via C wrapper) so that
/// interrupted syscalls are automatically restarted by the kernel.
/// Also unblocks the signals in case the parent process blocked them.
///
/// Safe to call multiple times — subsequent installs replace prior
/// handlers.
public func installShutdownSignalHandlers() {
    #if canImport(Glibc)
    // The handler closure is a C function pointer (@convention(c)).
    // It accesses only the module-level `shutdownFlag` global — no
    // captures, which is required for @convention(c) closures.
    let handler: @convention(c) (Int32) -> Void = { _ in
        shutdownFlag.store(true, ordering: .releasing)
    }
    sl_install_shutdown_handlers(handler)
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
