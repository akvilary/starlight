// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.
import PackageDescription

// Starlight — high-performance, zero-allocation HTTP framework for Swift 6.2+
// Built on SwiftNIO + thread-per-core model inspired by H2O, with the ownership
// discipline of Rust/Tokio and the per-request reuse pattern of fasthttp.

let package = Package(
    name: "Starlight",
    platforms: [
        // Span / MutableSpan / OutputSpan (SE-0447/0467/0485) and InlineArray (SE-0453)
        // ship in Swift 6.2 — pick platforms whose stdlib carries those symbols.
        .macOS(.v15),
        .iOS(.v18),
        .tvOS(.v18),
        .watchOS(.v11),
    ],
    products: [
        // The umbrella product — pulls in everything.
        .library(name: "Starlight", targets: ["Starlight"]),
        // Granular products for users who only want a slice of the stack.
        .library(name: "StarlightCore", targets: ["StarlightCore"]),
        .library(name: "StarlightHTTP", targets: ["StarlightHTTP"]),
        .library(name: "StarlightRouting", targets: ["StarlightRouting"]),
        .library(name: "StarlightMiddleware", targets: ["StarlightMiddleware"]),
        .library(name: "StarlightServer", targets: ["StarlightServer"]),
        .executable(name: "starlight-benchmark", targets: ["StarlightBenchmark"]),
    ],
    dependencies: [
        // I/O substrate — epoll on Linux, kqueue on Darwin.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.79.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.29.0"),
        .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.27.0"),
        // Lock-free / lock primitives and ordered/unique containers.
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.1.0"),
    ],
    targets: [
        // ── Core: zero-allocation primitives ─────────────────────────────────
        .target(
            name: "StarlightCore",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "Atomics", package: "swift-atomics"),
                .product(name: "Collections", package: "swift-collections"),
            ],
            swiftSettings: baseSwiftSettings
        ),

        // ── HTTP/1.1 codec (SIMD parser, headers, request, response) ─────────
        .target(
            name: "StarlightHTTP",
            dependencies: [
                "StarlightCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            swiftSettings: baseSwiftSettings
        ),

        // ── Radix-trie router with zero-copy path params ─────────────────────
        .target(
            name: "StarlightRouting",
            dependencies: ["StarlightCore", "StarlightHTTP"],
            swiftSettings: baseSwiftSettings
        ),

        // ── Generic middleware protocol (monomorphized chain) ────────────────
        .target(
            name: "StarlightMiddleware",
            dependencies: ["StarlightCore", "StarlightHTTP"],
            swiftSettings: baseSwiftSettings
        ),

        // ── Server bootstrap: SO_REUSEPORT per-loop, NIOSSL ──────────────────
        .target(
            name: "StarlightServer",
            dependencies: [
                "StarlightCore",
                "StarlightHTTP",
                "StarlightRouting",
                "StarlightMiddleware",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOExtras", package: "swift-nio-extras"),
            ],
            swiftSettings: baseSwiftSettings
        ),

        // ── Public umbrella (result-builder DSL, app entry) ──────────────────
        .target(
            name: "Starlight",
            dependencies: [
                "StarlightCore",
                "StarlightHTTP",
                "StarlightRouting",
                "StarlightMiddleware",
                "StarlightServer",
            ],
            swiftSettings: baseSwiftSettings
        ),

        // ── Benchmark executable (Phase 0: TCP echo) ─────────────────────────
        .executableTarget(
            name: "StarlightBenchmark",
            dependencies: [
                "Starlight",
                "StarlightServer",
                "StarlightCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Atomics", package: "swift-atomics"),
            ],
            swiftSettings: baseSwiftSettings
        ),

        // ── Tests ────────────────────────────────────────────────────────────
        .testTarget(
            name: "StarlightCoreTests",
            dependencies: [
                "StarlightCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            swiftSettings: baseSwiftSettings
        ),
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
    ]
)

// Swift 6.2 settings shared by every Starlight target.
//
// These four flags are the *core* of the framework's performance promise —
// each one is a load-bearing architectural decision, not a stylistic preference:
//
//  - Lifetimes (experimental): powers `Span`/`MutableSpan`-returning APIs
//    (SE-0447/0467). Without it we cannot express zero-copy byte views with
//    compile-time use-after-free protection — the central currency type.
//    The SwiftLSG guarantees a ≥3-release migration window once the official
//    replacement lands, so this is safe to adopt on 6.2+ for a new framework.
//
//  - NonisolatedNonsendingByDefault (SE-0466 upcoming): nonisolated `async`
//    functions run on the caller's executor by default instead of hopping to
//    the global concurrent pool. This is what makes thread-per-core actually
//    work — without it every `await` on a `Connection`-actor pinned to an
//    NIO `EventLoop` would defeat the pinning.
//
//  - ExistentialAny (upcoming): forces every boxed protocol type to be spelled
//    `any P`. Catches accidental existentials in the middleware chain (which
//    must stay monomorphized to remain zero-cost, à la Rust's Tower).
//
//  - StrictMemorySafety (experimental): surfaces unsafe constructs as errors
//    in the hot path. We will lean on raw pointers and `~Copyable` types
//    throughout; this flag keeps that surface audited.
//
// SPM applies `swiftSettings` only to our own targets, not to dependencies,
// so NIO/NIOSSL keep their own settings — the flags police *our* code only.
var baseSwiftSettings: [SwiftSetting] {
    [
        .enableExperimentalFeature("Lifetimes"),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
        .enableUpcomingFeature("ExistentialAny"),
        .enableExperimentalFeature("StrictMemorySafety"),
    ]
}
