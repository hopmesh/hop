// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RnMacPeer",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../../drivers/apple/HopDriver"),
    ],
    targets: [
        .executableTarget(
            name: "RnMacPeer",
            dependencies: [.product(name: "HopDriver", package: "HopDriver")]
        ),
    ]
)
