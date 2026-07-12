// swift-tools-version:5.9
import PackageDescription

// HopDemoKit - the pure, UI-independent logic extracted from the HopDemo iOS app so it can be
// unit-tested headlessly with macOS `swift test` (no app host, no device, no simulator).
//
// The demo app (apple/HopDemo) is an XcodeGen application project, not a SwiftPM package, and its
// screens are SwiftUI View bodies plus UIKit/AVFoundation camera, WebKit, PhotosUI, and Background-
// Tasks glue - none of which run under a headless `swift test`. The deterministic helpers those
// screens call (transport-icon/tag mapping, peer subline, message-meta formatting, hops:// URL
// normalization, MIME/content-type parsing, request-path building, QR payload encode/decode, the
// automation-URL/env parsers, and the CoreImage/ImageIO QR-bitmap + photo-downscale builders) are
// deterministic and portable, so they live here and are exercised directly. This package has NO
// dependency on HopDriver (and therefore needs no prebuilt xcframework), so it tests in isolation.
let package = Package(
    name: "HopDemoKit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "HopDemoKit", targets: ["HopDemoKit"]),
    ],
    targets: [
        .target(name: "HopDemoKit"),
        .testTarget(name: "HopDemoKitTests", dependencies: ["HopDemoKit"]),
    ]
)
