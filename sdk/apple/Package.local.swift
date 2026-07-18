// swift-tools-version:5.9
import PackageDescription

// Deterministic local-development manifest. Use only after build-xcframework.sh has generated and
// verified Frameworks/libhop.xcframework. Package.swift remains the published remote-binary contract.
let package = Package(
    name: "Hop",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "HopContract", targets: ["HopContract"]),
        .library(name: "Hop", targets: ["Hop"]),
    ],
    targets: [
        .target(name: "HopContract"),
        .binaryTarget(name: "CHop", path: "Frameworks/libhop.xcframework"),
        .target(name: "Hop", dependencies: ["CHop", "HopContract"]),
        .executableTarget(name: "HopSmoke", dependencies: ["Hop"]),
        .executableTarget(name: "RuntimeSmoke", dependencies: ["Hop", "HopContract"]),
        .testTarget(name: "HopContractTests", dependencies: ["HopContract"]),
        .testTarget(name: "HopRuntimeTests", dependencies: ["Hop", "HopContract"]),
    ]
)
