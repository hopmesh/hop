# HopDemo — Android chat (the same mesh as iOS)

An Android chat app running a `HopNode` over a foreground BLE + L2CAP bearer. Same
shared fabric UUID as the iOS app, so an Android device and an iPhone discover and
relay for each other (DESIGN.md §17).

> The Kotlin here is written against the UniFFI bindings but **not compiled in this
> repo's CI** — building it needs the Android SDK + NDK. Build it in Android Studio.

## Prerequisites (one-time)

```sh
# Android SDK + NDK (or use Android Studio's SDK Manager instead)
brew install --cask android-commandlinetools
sdkmanager "platform-tools" "platforms;android-34" "build-tools;34.0.0" "ndk;26.3.11579264"
export ANDROID_NDK_HOME="$(dirname "$(command -v sdkmanager)")/../../ndk/26.3.11579264"

cargo install cargo-ndk
rustup target add aarch64-linux-android x86_64-linux-android armv7-linux-androideabi
```

## Build the native libs + Kotlin bindings

```sh
./android/build-aar.sh
```

Produces (gitignored) under `android/HopDemo/generated/`:
- `jniLibs/<abi>/libhop.so` — the native libraries (wired in via `sourceSets`)
- `kotlin/uniffi/hop/hop.kt` — the generated bindings (wired in via `sourceSets`)

## Build & run the app

Open `android/HopDemo` in Android Studio and run on two devices, **or** CLI:

```sh
cd android/HopDemo
./gradlew installDebug      # with both devices in dev mode / USB
```

(If there's no Gradle wrapper yet, run `gradle wrapper` once in `android/HopDemo`,
or open the folder in Android Studio which generates it.)

## Use it

1. Launch on each device, grant the Bluetooth permissions.
2. Each lists the others under **People nearby** (by device model name).
3. Tap a person → type → **Send**. It arrives in their chat.

With three devices in a line (two out of range of each other), the middle one
**relays** — the node logic for it is already proven in Rust
(`relays_across_an_intermediate_node`).

## Background (DESIGN.md §22)

- A **foreground service** (`HopService`, `foregroundServiceType=connectedDevice`,
  persistent notification) owns the shared bearer so BLE keeps running and relaying
  when the app isn't on screen, without background-scan throttling.
- **Local notifications** fire on a delivered message while the app is backgrounded
  (`POST_NOTIFICATIONS` on Android 13+). No server / FCM — the push is local.
- Next: offloaded scanning via `startScan(PendingIntent)` to wake on a Hop-service
  match even when the process isn't running, and `WorkManager` for periodic ticks.

## Notes

- `minSdk = 29` — L2CAP CoC (`createInsecureL2capChannel`) requires API 29+.
- The bearer only calls `connected` / `received` / `drainOutgoing` / `tick`; all
  protocol logic stays in `hop-core`.
