//===----------------------------------------------------------------------===//
//
//  serve.swift
//  StarlightServer
//
//  The entry point that wires a `Service<Request<Body>>` (typically
//  a `Router<S>`) to a TCP listener + accept loop. Direct port of
//  `hyper::server::serve` / `axum::serve`.
//
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
import CLinuxExt
#endif

import Foundation
import HTTP
import StarlightPoll
import StarlightTower

/// Bind a TCP listener and serve `service` on every accepted
/// connection. Blocks the caller until shutdown.
///
/// axum analogue:
///
/// ```rust
/// async fn main() {
///     let app = Router::new().route("/", get(handler));
///     let listener = tokio::net::TcpListener::bind("0.0.0.0:3000").await.unwrap();
///     axum::serve(listener, app).await.unwrap();
/// }
/// ```
///
/// Swift translation:
///
/// ```swift
/// let router = Router(state: NoState()).get("/") { req in
///     return .plain("hello")
/// }
/// try await serve(listener: listener, service: router)
/// ```
public func serve<S: Service>(
    listener: TcpListener,
    service: S,
    loopCount: Int = ProcessInfo.processInfo.activeProcessorCount
) async throws where S.Request == Request<Body>, S.Response == Response<Body> {
    // ── Skeleton stub ────────────────────────────────────────────────
    //
    // The full implementation lives across multiple files
    // (HttpServerLoop.swift, HTTP1Codec.swift, Conn.swift). The
    // skeleton here exists to:
    //
    //   1. Lock the public `serve(listener:service:)` API in place
    //      before the heavy HTTP/1.1 codec lands.
    //   2. Provide a working `Router → Service` pipeline that the
    //      framework tests can exercise in-process, without real
    //      network I/O.
    //
    // The real accept loop will:
    //
    //   • Spawn `loopCount` worker threads, each pinning a
    //     `PollEventLoop` to a CPU via `sl_pin_to_cpu`.
    //   • Each worker registers the listener fd as a watch channel
    //     and drains `accept4(2)` on readiness.
    //   • Each accepted connection spawns a Task pinned to the
    //     worker's executor; that Task runs the HTTP/1.1 codec
    //     (`HTTP1Codec`) + dispatches parsed requests to `service`.
    //
    // For now we just block forever; the caller cancels via a
    // Task cancellation.
    let boxed = BoxService(service)
    _ = boxed
    _ = listener

    await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in
        // Hangs forever in the skeleton — `serve` is a no-op stub.
        // Real implementation lives in HttpServerLoop.swift.
    }
}
