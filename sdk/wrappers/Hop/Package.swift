// swift-tools-version:5.9
import PackageDescription

// Hop — the thin idiomatic Swift face of libhop's C ABI (hop.h). `CHop` is the generated C contract,
// shipped as the `libhop.xcframework` binary target (built by build-xcframework.sh: hop.h + the static
// lib for ios-arm64 + ios-sim + macOS). `Hop` wraps those C calls in Swift types. Because the
// xcframework carries the static lib, the whole stack — bearers, driver, app — builds + LINKS for iOS
// devices and macOS with no manual -L/-l flags. Bearers and apps depend on `Hop`, never the raw header.
//
// First build / after editing cabi.rs: run build-xcframework.sh (regenerates the xcframework; it's a
// gitignored artifact, like apple/HopDriver's). The module Hop.swift imports is `CHop` (the xcframework
// module map).
let package = Package(
    name: "Hop",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "Hop", targets: ["Hop"]),
    ],
    targets: [
        .binaryTarget(name: "CHop", path: "Frameworks/libhop.xcframework"),
        .target(name: "Hop", dependencies: ["CHop"]),
        .executableTarget(name: "HopSmoke", dependencies: ["Hop"]),
        .executableTarget(name: "RuntimeSmoke", dependencies: ["Hop"]),
    ]
)
