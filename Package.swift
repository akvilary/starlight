// swift-tools-version: 6.2
//
//  Starlight — high-performance HTTP framework for Swift 6.2+
//
//  Architectural mirror of the Rust `axum` workspace, ported to Swift:
//
//    ┌──────────────────────┬─────────────────────────────────────┐
//    │ Swift module         │ Rust analogue                       │
//    ├──────────────────────┼─────────────────────────────────────┤
//    │ StarlightPoll        │ tokio::runtime (reactor) — wraps    │
//    │                      │ the mio package (epoll primitives)  │
//    │ StarlightTower       │ tower::{Service, Layer}             │
//    │ StarlightHTTP        │ http + hyper types (Request,        │
//    │                      │ Response, HeaderMap, Method, …)     │
//    │ StarlightServer      │ hyper::server + tokio::net          │
//    │                      │ (TcpListener, TcpStream, HTTP codec)│
//    │ StarlightCore        │ axum-core (Handler, IntoResponse,   │
//    │                      │ FromRequest, FromRequestParts)      │
//    │ StarlightRouting     │ axum::routing (Router<S>,           │
//    │                      │ MethodRouter, Route, Fallback)      │
//    │ StarlightExtractors  │ axum::extract (State, Path, Query,  │
//    │                      │ Json, Form, Bytes, …)               │
//    │ StarlightMiddleware  │ axum::middleware + tower-http       │
//    │                      │ (from_fn, Compression, …)           │
//    │ Starlight            │ axum umbrella + serve()             │
//    │ CLinuxExt            │ libc wrappers (accept4,             │
//    │                      │ sched_setaffinity)                  │
//    └──────────────────────┴─────────────────────────────────────┘
//
//  Foundation dependencies kept from the previous design:
//
//    • MIO (https://github.com/akvilary/mio) — Swift port of Rust mio
//      (epoll primitives: Poll/Registry/Token/Interest/Events/Waker).
//      Identical role to the mio crate in the tokio ecosystem.
//
//  Dropped on this branch:
//
//    • StarlightIORing / SystemPackage.IORing — io_uring backend.
//      axum uses epoll via mio; we mirror that decision. io_uring
//      complexity is not justified vs. a well-tuned epoll loop.
//
//  Compiler features required (Swift 6.2+):
//
//    • NonisolatedNonsendingByDefault (SE-0466) — nonisolated `async`
//      functions stay on the caller's executor. This is what makes
//      thread-per-core actually work — without it every `await` on
//      a connection handler pinned to a PollEventLoop would defeat
//      the pinning.
//
//    • Lifetimes (experimental) — required for Span/MutableSpan
//      (SE-0447/0467), which underpins zero-copy request parsing.
//
//    • StrictMemorySafety (experimental) — surfaces unsafe
//      constructs as errors in the hot path.

import PackageDescription

let package = Package(
    name: "Starlight",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .tvOS(.v18),
        .watchOS(.v11),
    ],
    products: [
        // Public umbrella (the `axum` crate analogue).
        .library(name: "Starlight", targets: ["Starlight"]),

        // axum-core analogue.
        .library(name: "StarlightCore", targets: ["StarlightCore"]),

        // tower analogue.
        .library(name: "StarlightTower", targets: ["StarlightTower"]),

        // hyper::server + tokio::net analogue.
        .library(name: "StarlightServer", targets: ["StarlightServer"]),

        // axum::routing analogue.
        .library(name: "StarlightRouting", targets: ["StarlightRouting"]),

        // axum::extract analogue.
        .library(name: "StarlightExtractors", targets: ["StarlightExtractors"]),

        // axum::middleware + tower-http analogue.
        .library(name: "StarlightMiddleware", targets: ["StarlightMiddleware"]),

        // tokio::runtime analogue (epoll reactor on top of mio).
        .library(name: "StarlightPoll", targets: ["StarlightPoll"]),

        // Hello-world example executable (smoke test for the server).
        .executable(name: "hello-world", targets: ["HelloWorld"]),
    ],
    dependencies: [
        // mio — epoll-backed readiness I/O primitives (Poll/Registry/
        // Token/Interest/Ready/Event/Events/Waker). Swift port of
        // Rust's mio. https://github.com/akvilary/mio
        .package(url: "https://github.com/akvilary/mio.git", from: "0.1.1"),
        // http — pure HTTP message types (Request/Response/Method/
        // StatusCode/HeaderMap/Uri/Version/Body). Swift port of the
        // Rust `http` crate. https://github.com/akvilary/http
        .package(path: "../http"),
        // hyper — HTTP/1.1 codec + connection driver (Conn/Decoder/
        // Dispatcher/Encoder). Swift port of the Rust `hyper` crate.
        // https://github.com/akvilary/hyper
        .package(path: "../hyper"),
    ],
    targets: [
        // ── C wrappers for GNU-extension syscalls (accept4,
        //    sched_setaffinity). Kept from the previous design —
        //    Swift's Glibc module does not re-export them. ─────────
        .target(
            name: "CLinuxExt",
            path: "Sources/CLinuxExt",
            publicHeadersPath: "include"
        ),

        // ── StarlightPoll — tokio::runtime analog. ────────────────
        //
        // High-level Swift Concurrency event loop driven by mio's
        // `Poll`. Provides SerialExecutor + TaskExecutor + async
        // read/write API. The reactor on top of which all higher
        // layers are built. Depends on StarlightCore for
        // `PaddedAtomicInt64` (cross-loop stats counters).
        .target(
            name: "StarlightPoll",
            dependencies: pollDependencies,
            path: "Sources/StarlightPoll",
            swiftSettings: baseSwiftSettings
        ),

        // ── StarlightTower — tower::{Service, Layer} analog. ──────
        //
        // The `Service<Request> -> Response` trait abstraction that
        // axum/hyper/tower are built around. Includes the type-erased
        // `BoxService` (tower's `Service` trait object).
        .target(
            name: "StarlightTower",
            dependencies: [],
            path: "Sources/StarlightTower",
            swiftSettings: baseSwiftSettings
        ),

        // ── StarlightServer — hyper::server + tokio::net analog. ──
        //
        // `TcpListener` (SO_REUSEPORT, multi-loop), `TcpStream` (async
        // read/write via PollEventLoop), and a `serve(listener:service:)`
        // entry point that wraps hyper's HTTP1Builder.
        .target(
            name: "StarlightServer",
            dependencies: serverDependencies,
            path: "Sources/StarlightServer",
            swiftSettings: baseSwiftSettings
        ),

        // ── StarlightCore — axum-core analog. ─────────────────────
        //
        // The `Handler` protocol (function-like → Service adapter),
        // `IntoResponse` (anything convertible to a `Response`), and
        // the `FromRequest`/`FromRequestParts` extractor protocols.
        .target(
            name: "StarlightCore",
            dependencies: [
                .product(name: "HTTP", package: "http"),
                "StarlightTower",
            ],
            path: "Sources/StarlightCore",
            swiftSettings: baseSwiftSettings
        ),

        // ── StarlightRouting — axum::routing analog. ──────────────
        //
        // `Router<S>` (generic over app state), `MethodRouter<S>`,
        // `Route<S>` (per-path service), `Fallback`. Path matching,
        // method dispatch, route nesting.
        .target(
            name: "StarlightRouting",
            dependencies: [
                "StarlightCore",
                .product(name: "HTTP", package: "http"),
                "StarlightTower",
            ],
            path: "Sources/StarlightRouting",
            swiftSettings: baseSwiftSettings
        ),

        // ── StarlightExtractors — axum::extract analog. ───────────
        //
        // Built-in extractors: `State<S>`, `Path<T>`, `Query<T>`,
        // `Json<T>`, `Form<T>`, `Bytes`, `String`, `Request`.
        .target(
            name: "StarlightExtractors",
            dependencies: [
                "StarlightCore",
                .product(name: "HTTP", package: "http"),
            ],
            path: "Sources/StarlightExtractors",
            swiftSettings: baseSwiftSettings
        ),

        // ── StarlightMiddleware — axum::middleware + tower-http. ──
        //
        // `from_fn` style middleware builder, plus common middleware
        // (compression, trace, auth, CORS). All built as `Layer`s.
        .target(
            name: "StarlightMiddleware",
            dependencies: [
                "StarlightCore",
                "StarlightExtractors",
                .product(name: "HTTP", package: "http"),
                "StarlightTower",
            ],
            path: "Sources/StarlightMiddleware",
            swiftSettings: baseSwiftSettings
        ),

        // ── Starlight — public umbrella. ──────────────────────────
        //
        // Re-exports every submodule and provides `serve(router:)`
        // — the entry point matching `axum::serve`.
        .target(
            name: "Starlight",
            dependencies: [
                "StarlightCore",
                .product(name: "HTTP", package: "http"),
                .product(name: "Hyper", package: "hyper"),
                "StarlightTower",
                "StarlightServer",
                "StarlightRouting",
                "StarlightExtractors",
                "StarlightMiddleware",
                "StarlightPoll",
            ],
            path: "Sources/Starlight",
            swiftSettings: baseSwiftSettings
        ),

        // ── Tests ──────────────────────────────────────────────────
        .testTarget(
            name: "StarlightTowerTests",
            dependencies: ["StarlightTower"],
            path: "Tests/StarlightTowerTests",
            swiftSettings: baseSwiftSettings
        ),
        .testTarget(
            name: "StarlightCoreTests",
            dependencies: ["StarlightCore"],
            path: "Tests/StarlightCoreTests",
            swiftSettings: baseSwiftSettings
        ),
        .testTarget(
            name: "StarlightPollTests",
            dependencies: ["StarlightPoll"],
            path: "Tests/StarlightPollTests",
            swiftSettings: baseSwiftSettings
        ),
        .testTarget(
            name: "StarlightRoutingTests",
            dependencies: [
                "StarlightRouting",
                "StarlightCore",
                "StarlightExtractors",
                "StarlightMiddleware",
                "StarlightTower",
                .product(name: "HTTP", package: "http"),
            ],
            path: "Tests/StarlightRoutingTests",
            swiftSettings: baseSwiftSettings
        ),
        .testTarget(
            name: "StarlightServerTests",
            dependencies: [
                "Starlight",
                .product(name: "HTTP", package: "http"),
                .product(name: "Hyper", package: "hyper"),
            ],
            path: "Tests/StarlightServerTests",
            swiftSettings: baseSwiftSettings
        ),

        // ── Hello-world executable (smoke test) ────────────────────
        .executableTarget(
            name: "HelloWorld",
            dependencies: [
                "Starlight",
                "StarlightServer",
                "StarlightMiddleware",
                .product(name: "HTTP", package: "http"),
                .product(name: "Hyper", package: "hyper"),
            ],
            path: "Sources/HelloWorld",
            swiftSettings: baseSwiftSettings
        ),
    ]
)

// Swift 6.2 settings shared by every Starlight target.
//
// See the file header for the rationale — these are load-bearing.
var baseSwiftSettings: [SwiftSetting] {
    [
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
        .enableExperimentalFeature("Lifetimes"),
        .enableExperimentalFeature("StrictMemorySafety"),
    ]
}

// ── Platform-conditional dependencies ────────────────────────────────────
//
// StarlightPoll wraps the mio package. On non-Linux platforms the mio
// module compiles to an empty shell (its sources are all #if os(Linux)),
// so the dependency remains declared but produces no symbols.

#if os(Linux)
var pollDependencies: [Target.Dependency] {
    [
        "StarlightCore",
        .product(name: "MIO", package: "mio"),
    ]
}
#else
var pollDependencies: [Target.Dependency] {
    [
        "StarlightCore",
        .product(name: "MIO", package: "mio"),
    ]
}
#endif

#if os(Linux)
var serverDependencies: [Target.Dependency] {
    [
        .product(name: "HTTP", package: "http"),
        .product(name: "Hyper", package: "hyper"),
        "StarlightPoll",
        "CLinuxExt",
    ]
}
#else
var serverDependencies: [Target.Dependency] {
    [
        .product(name: "HTTP", package: "http"),
        .product(name: "Hyper", package: "hyper"),
        "StarlightPoll",
    ]
}
#endif
