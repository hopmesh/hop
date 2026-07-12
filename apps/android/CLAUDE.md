# apps/android/

## HopDemo (the Android app)

A SwiftUI-equivalent Compose app that consumes `drivers/android/hop-driver` + `bearers/android/*`.

- **This is a SEPARATE gradle build from `bearers/android/`.** HopDemo runs AGP 9.x + Kotlin 2.x; `bearers/android/` runs AGP 8.5.2. They compile `hop-driver` independently. Do not assume one settings.gradle covers both.
- `settings.gradle.kts` includes the bearer + driver projects by relative path: `../../../drivers/android/hop-driver`, `../../../bearers/android/{hop-sdk,bearer-ble,bearer-lan,bearer-relay}`. HopDemo is 3 levels from the repo root, hence `../../../`. If you move it, fix that count.
- **UniFFI bindings + native libs are generated, not committed.** They live under `apps/android/HopDemo/generated/` (gitignored), produced by `cargo run ... uniffi-bindgen` + `tools/build-aar.sh`. `drivers/android/hop-driver` reads them back via `../../../apps/android/HopDemo/generated`. CI regenerates them before the gradle build.

## Build + test

See the "Android bearers + driver" and "android/HopDemo" steps in `.github/workflows/ci.yml` for the exact task list. Locally: build libhop (`cargo build -p hop`), generate the UniFFI Kotlin bindings, then run the app's gradle tasks. Java is per-repo via mise; export `JAVA_HOME` if gradlew cannot find it.

The demo app's pure logic is unit-tested + coverage-gated; the SwiftUI/Compose views + Keystore/radio glue are device-bound and excluded from the coverage denominator (covered by the on-device workflow).
