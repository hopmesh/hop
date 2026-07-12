# apps/

Every Hop app lives here, `apps/<platform>/<app>`, the repo-wide purpose/platform/package axis.

```
apps/apple/HopDemo       the iOS demo app (XcodeGen; a thin SwiftUI consumer of drivers/apple/HopDriver)
apps/apple/HopDemoKit    the iOS app's pure, non-UI logic (headless `swift test`, 95% coverage gate)
apps/android/HopDemo     the Android demo app (its OWN gradle build; consumes drivers/android + bearers/android)
apps/web/site            the Astro marketing site (hopme.sh); platform=web, app=site
apps/esp32/hop-sensor    the ESP32 sensor demo (pure C against sdk/hop.h)
apps/ble-lab             the BLE clean-room proof-of-pipe lab (SEE EXCEPTION below)
```

`apps/ble-lab` is the one deliberate exception to `apps/<platform>/<app>`. It is a single,
cohesive cross-platform experiment (a shared SPEC with `apple/`, `apple-ios/`, `android/` impls
that only make sense together), so the platform lives *inside* it (`apps/ble-lab/<platform>`),
the same way `core/` and `services/` carry no platform level because they are inherently
cross-platform. It is not a shipped product; do not split it into per-platform app dirs.

## What is NOT here

Platform BUILD tooling is not an app; it lives in `tools/` (`build-xcframework.sh` for the Apple SDK
xcframework, `build-aar.sh` for the Android bindings, `smoke-test.sh`). `drivers/` and `sdk/` depend on
those, so if you move them update every reference in `drivers/`, `sdk/`, CI, and docs.

## How apps consume the shared layers

An app never talks to `hop-core` directly. It links its platform **driver** (`drivers/apple/HopDriver`
or `drivers/android/hop-driver`), which owns the node + the bearer packages (`bearers/<platform>/*`).
The apps reach those via relative paths (`../../../drivers/...`, `../../../bearers/...`), so if the app
moves depth changes, fix the `../` count (see the per-platform CLAUDE.md).
