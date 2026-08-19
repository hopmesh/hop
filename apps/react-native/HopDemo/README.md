# HopDemo, React Native

The Hop demo app built once in React Native and run on both iOS and Android, alongside the two native
implementations in `apps/apple/HopDemo` (SwiftUI) and `apps/android/HopDemo` (Compose). Having the same
demo three ways is the point: it is the sharpest available test of whether the client SDKs really present
the same surface, and `src/demoFormat.ts` is a direct port of presentation logic that already exists twice
natively, so there is a parity target rather than a guess.

This replaces the React Native CLI's template README, which was generic boilerplate.

## State of the build

| platform | status |
|---|---|
| Android | builds and runs. `./gradlew :app:assembleDebug` produces a debug APK carrying `libhop.so` and `libjnidispatch.so` for arm64-v8a, armeabi-v7a, x86 and x86_64. |
| iOS | builds and runs on the simulator. The app bundle's `HopDemo.debug.dylib` carries 340 `hop_` C ABI symbols, `_hop_abi_version` among them, plus Rust provenance strings naming `core/hop-core/src/node.rs`. |

### How iOS is wired, and what used to be broken

`sdk/react-native/ios/HopMesh.swift` does `import Hop`. The Apple SDK now ships three podspecs, one per
Swift Package Manager target, and this app's `Podfile` points them at `sdk/apple`:

| pod | source in this app | module |
|---|---|---|
| `CHop` | `:podspec`, so the pinned, checksum-verified `libhop.xcframework` release asset is downloaded | `CHop` |
| `HopContract` | `:path` to `sdk/apple`, pure Swift from the working tree | `HopContract` |
| `HopSDK` | `:path` to `sdk/apple`, the SDK proper | `Hop` |

`CHop` is deliberately not a local path: the xcframework is a build output that is not committed, so there
would be nothing there to vendor. This way the Swift wrapper is local while the compiled core is the same
immutable artifact a published consumer resolves.

Three defects had to be fixed to get here, and each was hidden behind the previous one:

1. `HopMesh.podspec` reached the Apple SDK through `s.spm_dependency`, guarded by
   `if s.respond_to?(:spm_dependency)`. CocoaPods 1.17.0 has no such method, so the guard skipped silently
   and `pod ipc spec` evaluated to a spec whose only dependency was `React-Core`. `import Hop` could not
   resolve.
2. With the module resolving, `HopMesh.swift` turned out never to have compiled at all: it lacked
   `import React`, so `RCTEventEmitter` and the promise block types were all undefined. No CI job builds a
   React Native iOS app, so nothing had ever caught it.
3. With it compiling, the link failed. The Apple SDK pod was originally named `Hop`, which builds
   `libHop.a`, and macOS volumes are case-insensitive by default, so that is the same file name as the
   core's `libhop.a`. `-lhop` resolved to the Swift wrapper: first every `hop_` symbol was undefined, then,
   after also linking the core by explicit path, the wrapper was linked twice and the build failed with 129
   duplicate Swift symbols. Renaming the pod to `HopSDK` while keeping `module_name = "Hop"` makes the
   archive names genuinely distinct, and CocoaPods' own flags then resolve correctly with no manual linker
   settings.

Also worth knowing: `:podspec =>` external pods are cached under `ios/Pods/Local Podspecs`, and a plain
`pod install` silently kept using the stale copy after `CHop.podspec` changed. `rm -rf Pods Podfile.lock`
forces a re-read.

## What this app actually demonstrates

The React Native SDK ships no transport. Its surface is `linkUp` / `bytesReceived` / `onOutgoing`, and the
native demos get their radios from `drivers/apple` and `drivers/android`. So this app opens **two** Hop
nodes and pairs them over an in-process loopback bearer in `src/loopback.ts`. The UI says so on screen
rather than implying otherwise.

That loopback is not a mock. Bytes are produced by the real Rust core, sealed with real crypto, and
delivered through the real inbox, so a message shown as received genuinely round-tripped through
`hop-core`. What it cannot show is radio discovery or true multi-device relay, which is exactly why the
test suite splits along that line.

Two helpers are deliberately absent rather than stubbed: `makeQrBitmap` and `jpegDownscale` are platform
graphics APIs with no bundled React Native equivalent, and the UI states the QR code is unavailable
instead of rendering an empty box.

## Prerequisites

The Android SDK and NDK, a JDK, and the Rust Android targets. `mise` provides the JDK and Gradle in this
repo, so prefer `mise exec -- gradle` over a global install.

```sh
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export JAVA_HOME=/opt/homebrew/opt/openjdk@17
export PATH="$JAVA_HOME/bin:$PATH"
export PATH="$HOME/.cargo/bin:$PATH"   # rustup's cargo, not Homebrew's, which has no Android targets
```

Build and publish the Android SDK AAR to a local Maven repository first, because this app consumes
`sh.hop:hop` as a real Maven artifact so the JNA dependency arrives with it:

```sh
# from the repo root
sdk/android/build-aar-dev.sh --repository sdk/react-native/android/.hop-maven
```

Then install and build:

```sh
npm ci
(cd android && ./gradlew :app:assembleDebug)
```

## Running the tests

```sh
npm run e2e:guard          # the gate. Fast, no device. Keeps steps and app testIDs in lockstep.
npm run e2e:dry            # informational listing of scenarios and steps
npm run e2e:build:android  # detox build
npm run e2e:android        # detox run on an emulator
npm run e2e:multi          # lists the scenarios that need real hardware
```

`npm run e2e:guard` is the gate, and the dry run is not. `cucumber-js` does **not** fail on an undefined
step: it prints `Undefined` and exits 0, and neither `strict` in the config nor `--strict` on the command
line changes that. `e2e/testids.test.js` does fail, and it was proven to fail by sabotage in three
directions: renaming an app testID, deleting a step definition, and adding an undefined step to the
feature file.

Scenarios tagged `@multi-device` need two or three physical phones. Their steps throw pending naming the
hardware required and assert nothing, because a scenario that appeared to prove a mesh relay while running
alone on an emulator would be worse than no test at all.

## Notes

- Kotlin: this app compiles with Kotlin 2.2.10, a version it does not choose. React Native 0.87's
  included `@react-native/gradle-plugin` build pulls AGP 9.2.1, which depends on the Kotlin Gradle
  plugin 2.2.10, and that transitively wins conflict resolution for the app's versionless classpath
  entry. `sdk/android` is therefore pinned at the same 2.2.10 so the published AAR carries metadata
  2.2.0 that this compiler reads; the old metadata-check suppression in `android/build.gradle` is
  gone. The `kotlinVersion` in `android/build.gradle` matches the real compiler because third-party
  RN libraries read it to pick their `kotlin-stdlib`.
- The app declares the local Maven repository itself, not only in the SDK module. Gradle resolves
  transitive dependencies against the consumer's repository list, so without this `sh.hop:hop` is not
  found even when the module declares it.
