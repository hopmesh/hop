// swift-tools-version:5.9
import PackageDescription

// HopBearers — the cross-platform transport layer for Hop, as a family of INDEPENDENT libraries.
// There is NO master library: a small core defines the contract + registry, and each transport is its
// OWN library that depends only on the core. An app (or the clean room) pulls in just the bearers it
// wants and registers them with a BearerManager — so a BLE-only build never links LAN/relay code.
//
//   HopBearerCore   — the Bearer/LinkSink contract, BearerManager registry, shared log/hex helpers
//   HopBearerBle    — the BLE transport (CoreBluetooth)           [depends: Core]
//   HopBearerLan    — the LAN transport (mDNS + TCP)              [depends: Core]   (added next)
//   HopBearerRelay  — the relay transport (WebSocket)            [depends: Core]   (added next)
//   HopBearerProof  — the clean-room proof-of-pipe consumer       [depends: Core]
//
// Each bearer library names nothing outside its own transport; the core names nothing transport-
// specific. Pure CoreBluetooth/Foundation — NO Rust / hop-ffi dependency, so the lab builds standalone.
let package = Package(
    name: "HopBearers",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "HopBearerCore",  targets: ["HopBearerCore"]),
        .library(name: "HopBearerBle",   targets: ["HopBearerBle"]),
        .library(name: "HopBearerProof", targets: ["HopBearerProof"]),
        .executable(name: "blepeer", targets: ["blepeer"]),
    ],
    targets: [
        .target(name: "HopBearerCore"),
        .target(name: "HopBearerBle",   dependencies: ["HopBearerCore"]),
        .target(name: "HopBearerProof", dependencies: ["HopBearerCore"]),
        // Clean-room CLI: bootstraps a BearerManager, registers BleBearer, wires the shared ProofSink.
        .executableTarget(name: "blepeer", dependencies: ["HopBearerCore", "HopBearerBle", "HopBearerProof"]),
        // Deterministic registry tests (no radio): prove BearerManager's multiplexing/routing/id-space.
        .testTarget(name: "HopBearerCoreTests", dependencies: ["HopBearerCore"]),
    ]
)
