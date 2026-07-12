# apps/apple/

The Apple apps. Both are thin consumers of `drivers/apple/HopDriver` (the app-facing client).

## HopDemo (the iOS app)

- XcodeGen project (`project.yml`, gitignored `.xcodeproj`). Regenerate with `xcodegen` after editing `project.yml`.
- **Build the driver's binary artifacts first:** `tools/build-xcframework.sh` (produces the gitignored libhop xcframework + Swift bindings that HopDriver links). CI does this before the app build.
- Dependencies in `project.yml`: `HopDriver` at `../../../drivers/apple/HopDriver`, `HopDemoKit` at `../HopDemoKit` (its sibling). If you move HopDemo, fix the `../` depth (it is 3 levels from repo root now).
- The app is **build-only** in CI (no signing, no simulator); its logic is tested via HopDemoKit.

## HopDemoKit (the app's pure logic)

- A SwiftPM package holding the demo app's non-UI logic (formatting, parsing, QR + downscale bitmap builders) so it runs headlessly under macOS `swift test`. No HopDriver dependency.
- Coverage-gated: `tools/apple-cov-gate.sh apps/apple/HopDemoKit Sources/HopDemoKit/DemoFormat.swift 95`.
- The app's SwiftUI views / camera / WKWebView glue are UI/device-bound, live in HopDemo (not here), and are covered only by the build-only CI step + the on-device workflow.
