// swift-tools-version:5.9
import PackageDescription

// Hop — the thin idiomatic Swift face of libhop's C ABI (hop.h). `CHop` is the generated C contract,
// shipped as the `libhop.xcframework` binary target (built by build-xcframework.sh: hop.h + the static
// lib for ios-arm64 + ios-sim + macOS). `Hop` wraps those C calls in Swift types. Because the
// xcframework carries the static lib, the whole stack — bearers, driver, app — builds + LINKS for iOS
// devices and macOS with no manual -L/-l flags. Bearers and apps depend on `Hop`, never the raw header.
//
// Two products:
//   • HopContract — pure Swift, NO libhop: the Bearer/LinkSink/BearerManager contract + HopRole +
//     transport helpers. BEARERS depend on THIS, so a mobile app that drives the node via UniFFI
//     doesn't double-link the Rust core (it links libhop via neither — only the UniFFI xcframework).
//   • Hop         — the libhop node (HopNode over CHop) + HopRuntime. For standalone clients (ESP32,
//     the smokes) that want the C-ABI node directly.
//
// First build / after editing cabi.rs: run build-xcframework.sh (regenerates the gitignored xcframework).
let package = Package(
    name: "Hop",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "HopContract", targets: ["HopContract"]),
        .library(name: "Hop", targets: ["Hop"]),
    ],
    targets: [
        .target(name: "HopContract"),   // pure Swift — no libhop
        .binaryTarget(name: "CHop", path: "Frameworks/libhop.xcframework"),
        .target(name: "Hop", dependencies: ["CHop", "HopContract"]),
        .executableTarget(name: "HopSmoke", dependencies: ["Hop"]),
        .executableTarget(name: "RuntimeSmoke", dependencies: ["Hop", "HopContract"]),
        // core-ffi-09: pure-Swift multiplexer tests (no libhop) — the LinkId-mint/route/dedup logic
        // every iOS bearer routes through. Runs in a macOS CI job without the xcframework.
        .testTarget(name: "HopContractTests", dependencies: ["HopContract"]),
        // Full-stack HopRuntime + BearerManager + node (needs libhop via the xcframework in-tree).
        .testTarget(name: "HopRuntimeTests", dependencies: ["Hop", "HopContract"]),
    ]
)
