// swift-tools-version:5.9
import PackageDescription

// Hop, the thin idiomatic Swift face of libhop's C ABI (hop.h). `CHop` is the generated C contract,
// shipped as the `libhop.xcframework` binary target (built by build-xcframework.sh: hop.h + the static
// lib for ios-arm64 + ios-sim + macOS). `Hop` wraps those C calls in Swift types. Because the
// xcframework carries the static lib, the whole stack (bearers, driver, app) builds + LINKS for iOS
// devices and macOS with no manual -L/-l flags. Bearers and apps depend on `Hop`, never the raw header.
//
// Two products:
//   • HopContract, pure Swift, NO libhop: the Bearer/LinkSink/BearerManager contract + HopRole +
//     transport helpers. BEARERS depend on THIS, so a mobile app that drives the node via UniFFI
//     doesn't double-link the Rust core (it links libhop via neither, only the UniFFI xcframework).
//   • Hop        : the libhop node (HopNode over CHop) + HopRuntime. For standalone clients (ESP32,
//     the smokes) that want the C-ABI node directly.
//
// Published packages always resolve this immutable release asset. Local source development uses
// Package.local.swift through the documented local validation command; the published manifest never
// selects a machine-local or unverified framework.
let package = Package(
    name: "Hop",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "HopContract", targets: ["HopContract"]),
        .library(name: "Hop", targets: ["Hop"]),
    ],
    targets: [
        .target(name: "HopContract"),   // pure Swift, no libhop
        // CHop is the ONLY value in this repo that must be updated by measurement, never by hand.
        // The release job downloads the native-artifacts build for the source commit it is releasing
        // and asserts `swift package compute-checksum` on it equals the value below, so a stale
        // checksum does not degrade gracefully: it blocks the Apple, embedded, and Android releases
        // outright. It went stale twice because nothing recomputes it.
        //
        // The xcframework build IS reproducible: two different main commits (e01c12a6, ffbf377c)
        // produce a byte-identical zip, so this value is stable until core's COMPILED output changes.
        // That is the maintenance rule: a change to core/ (or sdk/hop.h) invalidates this checksum,
        // and the same change must bump the workspace version and update whatever depends on it.
        //
        // Measured, not inferred, from the native-release bundle of the `Native artifacts` run for
        // source ffbf377c490a33e3f5a5b35c2b199c09f1ab4b5a. To refresh: download that run's
        // native-release-bundle and run `swift package compute-checksum libhop.xcframework.zip`.
        // See docs/apple-release.md.
        .binaryTarget(
            name: "CHop",
            url: "https://github.com/hopmesh/hop-sdk-apple/releases/download/v0.0.2/libhop.xcframework.zip",
            checksum: "94c8986f199e158b866a619f473bf326bae7db9166f575f4bea0e182be864bc7"
        ),
        .target(name: "Hop", dependencies: ["CHop", "HopContract"]),
        .executableTarget(name: "HopSmoke", dependencies: ["Hop"]),
        .executableTarget(name: "RuntimeSmoke", dependencies: ["Hop", "HopContract"]),
        // core-ffi-09: pure-Swift multiplexer tests (no libhop), the LinkId-mint/route/dedup logic
        // every iOS bearer routes through. Runs in a macOS CI job without the xcframework.
        .testTarget(name: "HopContractTests", dependencies: ["HopContract"]),
        // Full-stack HopRuntime + BearerManager + node (needs libhop via the xcframework in-tree).
        .testTarget(name: "HopRuntimeTests", dependencies: ["Hop", "HopContract"]),
    ]
)
