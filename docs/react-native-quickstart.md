# React Native Quickstart

This guide walks you from a clean checkout of this repository (hopmesh/hop) to a running React Native app on both iOS and Android, using the `@hop-mesh/react-native` SDK.

## Prerequisites

Before you start, you need:

- A local checkout of this repository
- Node.js (v20 or later) and npm
- For iOS: Xcode, CocoaPods, and the iOS Rust targets installed (`rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios aarch64-apple-darwin x86_64-apple-darwin`)
- For Android: Android SDK, Android NDK, JDK 17, `cargo-ndk` (`cargo install cargo-ndk --locked --version 4.1.2`), and the Android Rust targets installed (`rustup target add aarch64-linux-android x86_64-linux-android armv7-linux-androideabi i686-linux-android`)

## Android: build the native dependency

The Android half of the SDK depends on the Kotlin SDK `sh.hop:hop`, which is not published to any remote Maven repository. You must build it locally and publish it to a local Maven repository first.

From the root of this repository, run:

```sh
./sdk/android/build-aar-dev.sh
```

This script compiles `libhop` for all four Android ABIs, packages it into an AAR, and publishes it to a local Maven repository at `sdk/android/build/maven-repository` (or the path you pass with `--repository`).

**Why this is needed:**
- `sh.hop:hop` was never published to Maven Central (metadata and POM both return 404; a group search for `sh.hop` returns nothing).
- The version `0.0.2` previously referenced was stale; the current version is `0.0.5`.
- The signed publishable path (`sdk/android/build-aar.sh`) is blocked because it requires the `NATIVE_ARTIFACT_SIGNING_KEY` secret and the published bundle does not include Android slices. It also fails because it compares against `sdk/android/include/hop.h`, which does not exist in the repository.
- The React Native Android module previously declared `implementation "com.facebook.react:react-native:+"`, which silently resolved to `0.71.0-rc.0` because modern React Native publishes `react-android` (versions 0.77 to 0.87) instead of `react-native`. The dependency has been updated to use `react-android` with a 0.77.3 floor.

After the script completes, export the repository path so Gradle can find it:

```sh
export HOP_MAVEN_REPOSITORY="$(pwd)/sdk/android/build/maven-repository"
```

Or point your app's `repositories` block at that path with `content { includeGroup "sh.hop" }`.

## iOS: build the native dependency

The iOS half depends on the Apple SDK `Hop`, which is built from source. You must build the XCFramework and Swift bindings first.

From the root of this repository, run:

```sh
./sdk/apple/build-xcframework.sh
```

This builds `libhop.xcframework` and places it at `sdk/apple/Frameworks/libhop.xcframework`.

**Why this is needed:**
- The XCFramework and Swift bindings are generated, not committed.
- The Apple SDK is consumed as three CocoaPods pods (`CHop`, `HopContract`, `HopSDK`), declared in the app's Podfile. CocoaPods cannot resolve a Swift Package Manager dependency, so the earlier claim that it could was wrong.

**Additional prerequisites (from `tools/`):**
- `tools/build-xcframework.sh`: Builds the Hop XCFramework and Swift bindings into the HopDriver package. This is the path for the native demo app; for React Native, use `sdk/apple/build-xcframework.sh` instead.
- `tools/build-aar.sh`: Generates the Android UniFFI bindings and native libs into the demo app's directory. This is the path for the native demo app; for React Native, use `sdk/android/build-aar-dev.sh` instead.

## Consuming the SDK in your app

The `@hop-mesh/react-native` package is marked `"private": true` in `package.json`, so it cannot be installed from npm. You have two options:

### Option 1: Local path (inside this repository)

If your app lives inside this repository, add the dependency as a local path:

```sh
npm install /path/to/hop/sdk/react-native
```

### Option 2: npm pack tarball (outside this repository)

If your app lives outside this repository, pack the SDK into a tarball and install that:

```sh
cd /path/to/hop/sdk/react-native
npm pack
cd /path/to/your-app
npm install /path/to/hop/sdk/react-native/hop-mesh-react-native-0.0.2.tgz
```

**Note:** The `npm pack` and `npm install` commands above have not been verified in this session. They are the standard npm workflow for local packages.

## iOS: install the pod

From your app's `ios` directory:

```sh
pod install
```

**Note:** The `pod install` command has not been verified in this session. It is the standard CocoaPods workflow.

The Apple SDK arrives as three pods, declared in the app's Podfile: `CHop` (the checksum-verified `libhop.xcframework` from the pinned release), `HopContract` (pure Swift), and `HopSDK` (the SDK proper, exposing the module `Hop`). Inside this repo they are local paths pointing at `sdk/apple`; outside it they come from `hopmesh/hop-sdk-apple`. See sdk/react-native/README.md for the exact Podfile lines.

The pod is `HopSDK` rather than `Hop` because a pod named `Hop` builds `libHop.a`, which collides with the core's `libhop.a` on a case-insensitive filesystem and makes the linker pick the wrong archive.

**Note on the podspec's `s.source`:** The podspec references git tag `v0.0.3`, but this repository carries no tags. This only affects remote pod consumption (e.g., `pod 'HopMesh', :git => '...'`). A development pod by local path (the default when you use `pod install` in an app inside this repository) is unaffected.

## Android: wire the repository

In your app's `android/build.gradle` (or `settings.gradle`), add the local Maven repository:

```groovy
repositories {
    maven {
        url = uri("/path/to/hop/sdk/android/build/maven-repository")
        content { includeGroup "sh.hop" }
    }
}
```

Then run your app as usual:

```sh
npx react-native run-android
```

**Note:** The `npx react-native run-android` command has not been verified in this session. It is the standard React Native CLI workflow.

## What is NOT ready

- **Publishing to Maven Central:** Requires Sonatype credentials and signing keys. This is a release decision, not a build step.
- **Dropping `"private": true` and tagging the repo:** These are shipping decisions that belong to the maintainers.
- **Native halves in CI:** The native code (Swift and Kotlin) was compiled nowhere in CI until this change. The only CI gate for this package is the JS typecheck and unit tests.

## Verification status

- **Android:** The command `./sdk/android/build-aar-dev.sh` has been run successfully on macOS (Darwin 25.5.0, Apple M5 Max) and produced a valid local Maven repository with `sh.hop:hop:0.0.5`.
- **iOS:** The command `./sdk/apple/build-xcframework.sh` has not been verified in this session. The exact sequence for building and running the iOS example app is being verified by another agent and will be updated here.
