// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.
import PackageDescription

// Starlight — high-performance HTTP framework for Swift 6.2+
// Built on SystemPackage.IORing (Linux) / SwiftNIO (macOS),
// thread-per-core model inspired by H2O, with the ownership discipline
// of Rust/Tokio and COW ByteBuffer reuse for zero-alloc-per-request
// header / body / response handling.

let package = Package(
    name: "Starlight",
    platforms: [
        // stdlib `Synchronization.Atomic` (SE-0433), `~Copyable` ownership
        // (SE-0390) and ` borrowing`/`consuming` (SE-0377) all require Swift
        // 6.2+. Span/InlineArray (SE-0447/0453/0485) are available for a
        // future zero-copy body view (Phase 3).
        .macOS(.v15),
        .iOS(.v18),
        .tvOS(.v18),
        .watchOS(.v11),
    ],
    products: [
        .library(name: "Starlight", targets: ["Starlight"]),
        .library(name: "StarlightCore", targets: ["StarlightCore"]),
        .library(name: "StarlightIORing", targets: ["StarlightIORing"]),
        .library(name: "StarlightHTTP", targets: ["StarlightHTTP"]),
        .library(name: "StarlightRouting", targets: ["StarlightRouting"]),
        .library(name: "StarlightServer", targets: ["StarlightServer"]),
        .executable(name: "starlight-benchmark", targets: ["StarlightBenchmark"]),
    ],
    dependencies: [
        // I/O substrate — io_uring on Linux (via SystemPackage.IORing),
        // epoll/kqueue fallback via SwiftNIO on all platforms.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.79.0"),
        // Apple SystemPackage — provides IORing (~Copyable ring management),
        // FileDescriptor, Errno. IORing requires main branch (unreleased).
        .package(url: "https://github.com/apple/swift-system.git", branch: "main"),
    ],
    targets: [
        // ── C wrappers for GNU-extension syscalls (accept4, eventfd, …) ────
        .target(
            name: "CLinuxExt",
            path: "Sources/CLinuxExt",
            publicHeadersPath: "include"
        ),

        // ── Core: synchronization primitives ─────────────────────────────────
        .target(
            name: "StarlightCore",
            dependencies: [],
            swiftSettings: baseSwiftSettings
        ),

        // ── io_uring event loop (Linux only — generic async I/O) ─────────────
        .target(
            name: "StarlightIORing",
            dependencies: ioringDependencies,
            swiftSettings: baseSwiftSettings
        ),

        // ── HTTP/1.1 codec (SWAR parser, headers, request, response) ─────────
        .target(
            name: "StarlightHTTP",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            swiftSettings: baseSwiftSettings
        ),

        // ── HTTP router with zero-copy path params ───────────────────────────
        .target(
            name: "StarlightRouting",
            dependencies: [
                "StarlightHTTP",
                .product(name: "NIOCore", package: "swift-nio"),
            ],
            swiftSettings: baseSwiftSettings
        ),

        // ── Server bootstrap: SO_REUSEPORT per-loop, IORing/NIO ──────────────
        .target(
            name: "StarlightServer",
            dependencies: serverDependencies,
            swiftSettings: baseSwiftSettings
        ),
        // ── Public umbrella (app entry point) ────────────────────────────────
        .target(
            name: "Starlight",
            dependencies: [
                "StarlightCore",
                "StarlightHTTP",
                "StarlightRouting",
                "StarlightServer",
            ],
            swiftSettings: baseSwiftSettings
        ),

        // ── Benchmark executable (TCP echo + HTTP + router) ──────────────────
        .executableTarget(
            name: "StarlightBenchmark",
            dependencies: [
                "Starlight",
                "StarlightServer",
                "StarlightHTTP",
                "StarlightRouting",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            swiftSettings: baseSwiftSettings
        ),

        // ── Tests ────────────────────────────────────────────────────────────
        .testTarget(
            name: "StarlightHTTPTests",
            dependencies: ["StarlightHTTP"],
            swiftSettings: baseSwiftSettings
        ),
        .testTarget(
            name: "StarlightRoutingTests",
            dependencies: ["StarlightRouting"],
            swiftSettings: baseSwiftSettings
        ),
        .testTarget(
            name: "StarlightServerTests",
            dependencies: [
                "StarlightServer",
                "StarlightHTTP",
                "StarlightRouting",
                .product(name: "NIOCore", package: "swift-nio"),
            ],
            swiftSettings: baseSwiftSettings
        ),
    ]
)

// Swift 6.2 settings shared by every Starlight target.
//
// These flags are the *core* of the framework's performance promise —
// each one is a load-bearing architectural decision, not a stylistic preference:
//
//  - NonisolatedNonsendingByDefault (SE-0466 upcoming): nonisolated `async`
//    functions run on the caller's executor by default instead of hopping to
//    the global concurrent pool. This is what makes thread-per-core actually
//    work — without it every `await` on a connection handler pinned to an
//    IORing loop would defeat the pinning.
//
//  - Lifetimes (experimental): required by SystemPackage.IORing
//    (`#if compiler(>=6.2) && $Lifetimes`). Enables `@_lifetime` annotations
//    and Span/MutableSpan (SE-0447/0467).
//
//  - StrictMemorySafety (experimental): surfaces unsafe constructs as errors
//    in the hot path. We lean on raw pointers and `~Copyable` types
//    throughout (io_uring SQE/CQE, zero-copy header views, COW ByteBuffer);
//    this flag keeps that surface audited.
//
// SPM applies `swiftSettings` only to our own targets, not to dependencies,
// so NIO / swift-system keep their own settings — the flags police *our* code
// only. swift-system already enables Lifetimes in its own Package.swift.
var baseSwiftSettings: [SwiftSetting] {
    [
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
        .enableExperimentalFeature("Lifetimes"),
        .enableExperimentalFeature("StrictMemorySafety"),
    ]
}

// ── Platform-conditional dependencies ────────────────────────────────────
//
// On Linux we use SystemPackage.IORing as the primary I/O backend, with
// NIO as a runtime fallback (gVisor, old Docker, kernel <5.7).
// On macOS NIO is the only backend.
// Both sets of dependencies are available on all platforms so the code
// compiles, but only the relevant path is executed.

#if os(Linux)
var ioringDependencies: [Target.Dependency] {
    [
        "StarlightCore",
        "CLinuxExt",
        .product(name: "SystemPackage", package: "swift-system"),
    ]
}
#else
var ioringDependencies: [Target.Dependency] {
    [
        "StarlightCore",
    ]
}
#endif

#if os(Linux)
var serverDependencies: [Target.Dependency] {
    [
        "StarlightIORing",
        "StarlightCore",
        "StarlightHTTP",
        "StarlightRouting",
        "CLinuxExt",
        .product(name: "SystemPackage", package: "swift-system"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
    ]
}
#else
var serverDependencies: [Target.Dependency] {
    [
        "StarlightCore",
        "StarlightHTTP",
        "StarlightRouting",
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
    ]
}
#endif
