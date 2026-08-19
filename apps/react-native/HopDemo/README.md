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

It runs two paths at once, and they prove different things.

**In-process loopback** (`src/loopback.ts`). Two Hop nodes in this process, paired with each other. Not a
mock: bytes are produced by the real Rust core, sealed with real crypto, and delivered through the real
inbox, so a message shown as received genuinely round-tripped through `hop-core`. It needs no network at
all, which is what makes a simulator run worth something. What it cannot do, by construction, is reach a
second device.

**A real relay bearer** (`src/relayBearer.ts`). A link from this device's node to a `hop-relayd` WebSocket
front door, which is how a node on ANOTHER device reaches this one. That door is an opaque byte pipe:
`services/hop-relayd/src/main.rs` says in its own module docs that "each link packet is exactly one WS
binary frame, so WS supplies the framing" and that "the bearer carries opaque bytes and knows nothing
about the protocol", and its test
`serve_ws_upgrade_bridges_binary_frames_both_ways_and_reports_down` pins that contract from the other side
against a real client. So the bearer adds nothing to the wire: no length prefix (that is the raw-TCP
bearer, path A), no hello, no auth message. One core packet, one binary frame, both directions.

So the earlier claim in this file, that the app cannot demonstrate device-to-device delivery, is no longer
true. What each thing proves, precisely:

| claim | status |
|---|---|
| two devices exchange a real, sealed message through a real relay | the relay bearer is what makes this possible: the sender seals, the relay carries ciphertext it cannot read, the receiver opens it |
| radio discovery | still NOT demonstrated, and not possible here. The React Native SDK ships no BLE and no LAN bearer, so nothing is discovered. A peer is reached by pasting its address |
| the relay accepted this node | NOT what `relay-status: up` means. `up` is the socket plus the core link. The bearer cannot read the protocol, so only a message arriving proves the handshake completed |

The relay URL comes from `HOP_RELAY_URL`, falling back to `wss://relay.hopme.sh/`, and it is editable on
screen. The editable field is not a convenience: React Native's `setUpGlobals` defines `process.env`
carrying `NODE_ENV` only, and Metro's inline plugin substitutes exactly `process.env.NODE_ENV` and
`__DEV__`, so an arbitrary environment variable is undefined in a device build. Pointing two phones at a
relay on a LAN address therefore has to be doable at runtime, and it is.

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
npx jest                   # unit tests, including the relay bearer's framing. No device, no relay.
```

`npm run e2e:guard` is the gate, and the dry run is not. `cucumber-js` does **not** fail on an undefined
step: it prints `Undefined` and exits 0, and neither `strict` in the config nor `--strict` on the command
line changes that. `e2e/testids.test.js` does fail, and it was proven to fail by sabotage in three
directions: renaming an app testID, deleting a step definition, and adding an undefined step to the
feature file.

`__tests__/relayBearer.test.ts` is the framing proof, and it is the reason no hardware is needed to trust
the bearer. It drives `connectRelay` against a fake WebSocket and a fake node and pins the wire behaviour
that fails invisibly: one outgoing packet becomes exactly one binary frame carrying the same bytes and no
header, one inbound frame becomes exactly one `bytesReceived` with the same bytes, frames arriving before
the link is up are held rather than dropped, a text frame is refused instead of being fed to the core, and
a close takes the core link down and reports `down`. It was proven able to fail by prefixing one byte to
the outgoing frame, which is exactly the mistake that would otherwise show up as a relay dropping the link
during the Noise handshake.

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
