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
| iOS | does not build. `import Hop` cannot resolve, for the reason below. This is a defect in `sdk/react-native/HopMesh.podspec`, not a missing step here. |

### Why iOS does not build

`sdk/react-native/ios/HopMesh.swift` does `import Hop`, and the podspec only supplies that module through
`s.spm_dependency`, guarded by `if s.respond_to?(:spm_dependency)`. Under CocoaPods 1.17.0 that method
does not exist, so the guard silently skips and the pod is published without the dependency:

```
$ pod ipc spec sdk/react-native/HopMesh.podspec   # no spm keys, React-Core is the only dependency
$ grep -c XCRemoteSwiftPackageReference ios/Pods/Pods.xcodeproj/project.pbxproj   # 0
```

Fixing it is an SDK decision (vendor the Apple SDK into the pod, or publish a podspec for `sdk/apple`),
so it is not worked around here. `.detoxrc.js` keeps an accurate `ios.sim.debug` configuration so the
suite runs as soon as the module is available.

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

- Kotlin metadata: `sdk/android` builds with Kotlin 2.4.10 and React Native 0.87 pins the compiler at
  2.2.0, which cannot read that metadata. `android/build.gradle` carries a clearly labelled DEV-ONLY
  `-Xskip-metadata-version-check` and names the durable fix, which is to align the versions.
- The app declares the local Maven repository itself, not only in the SDK module. Gradle resolves
  transitive dependencies against the consumer's repository list, so without this `sh.hop:hop` is not
  found even when the module declares it.
