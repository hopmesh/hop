// swift-tools-version:5.9
import PackageDescription

// HopBearersApple: the aggregate ROOT manifest, exposing all five bearers as products of one package.
//
// The bearers are MONOREPO-ONLY packages. They are not published as a standalone SwiftPM package, so
// nothing outside this tree resolves them: in-tree consumers (drivers/apple/HopDriver) take one path
// dependency per bearer against the per-bearer Package.swift files. Those files are also what the
// monorepo builds and coverage-gates independently (tools/apple-cov-gate.sh runs `swift test` inside
// each one). SwiftPM ignores a manifest in a subdirectory that nothing references, so the two coexist,
// and each bearer stays its own PRODUCT here so a consumer links only the transports it wants ("1
// isolated lib per bearer").
//
// WHY THE SDK DEPENDENCY IS A URL RATHER THAN A PATH. `sdk/apple` and this directory `bearers/apple`
// share the final component "apple", which is a path dependency's identity, so SwiftPM read the package
// as depending on itself and refused with "cyclic dependency between packages HopBearersApple ->
// HopBearersApple requires tools-version 6.0 or later". Raising the manifest to tools-version 6.0 would
// push a Swift 6 toolchain requirement onto every consumer to work around a directory name, so this
// manifest names the published Apple SDK instead. The per-bearer packages keep their path dependency on
// the in-tree SDK and are what CI tests.
let package = Package(
    name: "HopBearersApple",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "HopBearerBle", targets: ["HopBearerBle"]),
        .library(name: "HopBearerLan", targets: ["HopBearerLan"]),
        .library(name: "HopBearerMultipeer", targets: ["HopBearerMultipeer"]),
        .library(name: "HopBearerRelay", targets: ["HopBearerRelay"]),
        .library(name: "HopBearerMeshtastic", targets: ["HopBearerMeshtastic"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hopmesh/hop-sdk-apple.git", from: "0.0.2"),
    ],
    targets: [
        // Sources stay in the per-bearer package layout, so each target points at where they already
        // live rather than moving a single file.
        .target(name: "HopBearerBle",
                dependencies: [.product(name: "HopContract", package: "hop-sdk-apple")],
                path: "HopBearerBle/Sources/HopBearerBle"),
        .target(name: "HopBearerLan",
                dependencies: [.product(name: "HopContract", package: "hop-sdk-apple")],
                path: "HopBearerLan/Sources/HopBearerLan"),
        .target(name: "HopBearerMultipeer",
                dependencies: [.product(name: "HopContract", package: "hop-sdk-apple")],
                path: "HopBearerMultipeer/Sources/HopBearerMultipeer"),
        .target(name: "HopBearerRelay",
                dependencies: [.product(name: "HopContract", package: "hop-sdk-apple")],
                path: "HopBearerRelay/Sources/HopBearerRelay"),
        .target(name: "HopBearerMeshtastic",
                dependencies: [.product(name: "HopContract", package: "hop-sdk-apple")],
                path: "HopBearerMeshtastic/Sources/HopBearerMeshtastic"),
    ]
)
