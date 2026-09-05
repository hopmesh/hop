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
        // Pinning only became POSSIBLE once the build was made reproducible. xcodebuild emitted the
        // xcframework's AvailableLibraries in nondeterministic order, so identical sources produced a
        // different Info.plist, zip, and checksum on every build, and no committed value could ever
        // survive the next one. sdk/apple/build-xcframework.sh now sorts those slices; that was the
        // only source of variance (extracting two differing artifacts showed every compiled library
        // byte-identical). Do not remove that sort, or this pin silently becomes unmaintainable again.
        //
        // The second source of variance arrived with SQLCipher (ABI-001): vendored OpenSSL stamps
        // cversion.c with the build clock, so two CI builds of identical inputs differed in exactly
        // one object (REL-009). sdk/apple/build-xcframework.sh pins SOURCE_DATE_EPOCH for that reason.
        // With both in place the value is stable until core's COMPILED output changes. That is the
        // maintenance rule: a change to core/ (or sdk/hop.h) invalidates this checksum, and the same
        // change must bump the workspace version and update whatever depends on it.
        //
        // Measured, not inferred, from the native-release bundle of the `Native artifacts` run
        // 33942180382 for source 37a620b432a1a1968ec1bbb503c5f1b02ca3083f, attempts 1 AND 2 of which produced
        // byte-identical archives (REL-009 proof), verified with `native-artifacts.py verify-provenance`
        // against the rotated tools/native-artifacts-public.pem before this value was committed (ABI-008).
        // Its hop.h carries the current C ABI level, the one Sources/Hop/Hop.swift asserts (the pin
        // guard proves this on every run). To move the pin again, follow docs/apple-release.md.
        // tools/apple-pin-guard.py enforces compatibility and catches header/source drift.
        .binaryTarget(
            name: "CHop",
            url: "https://github.com/hopmesh/hop-sdk-apple/releases/download/v0.0.3/libhop.xcframework.zip",
            checksum: "79f63ccb805b6bb407beaa98d35488e58c0245479aa58d41827309e836311571"
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
