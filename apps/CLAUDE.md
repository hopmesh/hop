# apps/

Every Hop app lives here, one directory per app, grouped by platform: `apps/<platform>/<App>`.

```
apps/apple/HopDemo       the iOS demo app (XcodeGen; a thin SwiftUI consumer of drivers/apple/HopDriver)
apps/apple/HopDemoKit    the iOS app's pure, non-UI logic (headless `swift test`, 95% coverage gate)
apps/android/HopDemo     the Android demo app (its OWN gradle build; consumes drivers/android + bearers/android)
apps/web                 the Astro marketing site (hopme.sh)
apps/ble-lab             the BLE clean-room proof-of-pipe lab (self-contained, not shipped)
apps/esp32/hop-sensor    the ESP32 sensor demo (pure C against sdk/hop.h)
```

## What is NOT here

Platform BUILD tooling is not an app and stays at the platform root, because `drivers/` and `sdk/`
depend on it: `apple/build-xcframework.sh` (builds the HopDriver xcframework), `apple/smoke-test.sh`,
`android/build-aar.sh`. If you move those, update every reference in `drivers/`, `sdk/`, CI, and docs.

## How apps consume the shared layers

An app never talks to `hop-core` directly. It links its platform **driver** (`drivers/apple/HopDriver`
or `drivers/android/hop-driver`), which owns the node + the bearer packages (`bearers/<platform>/*`).
The apps reach those via relative paths (`../../../drivers/...`, `../../../bearers/...`), so if the app
moves depth changes, fix the `../` count (see the per-platform CLAUDE.md).
