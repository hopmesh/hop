// swift-tools-version:5.9
import PackageDescription

// HopBearers — the cross-platform transport layer (BLE first; LAN / Wi-Fi Direct / relay to follow),
// shared verbatim by BOTH the clean-room test harness (ble-lab) and the production app (HopDriver).
// A bearer forms links to peers and shuttles bytes behind a tiny LinkSink contract; the consumer is
// either the clean-room PROOF pinger or the production HopNode adapter. One transport, two consumers —
// so a fix proven in the clean room is the app's fix the moment it lands here (no hand fold-back).
//
// Pure CoreBluetooth/Foundation — NO Rust / hop-ffi dependency, so the lab keeps building standalone.
let package = Package(
    name: "HopBearers",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "HopBearers", targets: ["HopBearers"]),
    ],
    targets: [
        .target(name: "HopBearers"),
    ]
)
