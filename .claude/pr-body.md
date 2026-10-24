# Align the Kotlin versions, drop the metadata-check suppression

Jason's instruction: "align the kotlin versions". The React Native HopDemo's
`android/build.gradle` carried a DEV-ONLY block adding `-Xskip-metadata-version-check` to every
Kotlin compile task. This PR deletes it by making the versions genuinely agree, and corrects the
record: the mechanism the removed comment described was wrong in its details.

## What was actually happening (measured, not theorized)

**Where each side's Kotlin is pinned:**

| side | version | pinned at |
|---|---|---|
| Hop SDK AAR (`sh.hop:hop:0.0.5`) | Kotlin 2.4.10 (before) | `sdk/android/build.gradle.kts:10` |
| RN app compiler | Kotlin 2.2.10 | nowhere in this repo: it falls out of resolution, see below |
| RN's own KGP request | 2.2.0 | `node_modules/@react-native/gradle-plugin/gradle/libs.versions.toml:7` |
| AGP's KGP request | 2.2.10 | transitive from `com.android.tools.build:gradle:9.2.1` |

**How the app's compiler is decided.** The app's root `build.gradle` declares
`classpath("org.jetbrains.kotlin:kotlin-gradle-plugin")` with no version. `./gradlew
buildEnvironment` (node_modules populated this time; the earlier void measurement is not cited)
shows the resolution chain:

- `com.facebook.react:react-native-gradle-plugin -> project :gradle-plugin:react-native-gradle-plugin`
  (substitution to RN's included build), which requests AGP 9.2.1 and `kotlin-gradle-plugin:2.2.0`;
- AGP 9.2.1 itself depends on `kotlin-gradle-plugin:2.2.10`;
- ordinary conflict resolution picks 2.2.10 for the root classpath.

So the compiler family is 2.2.x and reads Kotlin metadata up to 2.3.0. The old comment claimed RN
"pins the compiler at 2.2.0 through its included build, because Gradle applies one Kotlin plugin
per build and RN's included build wins". Two errors: RN requests 2.2.0 but AGP's 2.2.10 wins, and
there is no per-build plugin monopoly; what does happen is that `@hop-mesh/react-native`'s own
buildscript request for `${kotlinVersion}` is shadowed by parent-first classloader delegation from
the root classpath. Proven directly: `./gradlew :hop-mesh_react-native:buildEnvironment` shows the
module's classpath requesting KGP 2.4.10, yet `./gradlew :hop-mesh_react-native:dependencies
--configuration kotlinCompilerClasspath` resolves `kotlin-compiler-embeddable:2.2.10`.

**A second failure the suppression was hiding.** With the block deleted and the AAR still at
metadata 2.4.0, `:hop-mesh_react-native:compileDebugKotlin` failed first ("Class 'sh.hop.HopNode'
was compiled with an incompatible version of Kotlin. The actual metadata version is 2.4.0, but the
compiler version 2.2.0 can read versions up to 2.3.0."). After republishing the AAR at 2.2.10, the
next failure was `:react-native-safe-area-context:compileDebugKotlin` reading
`kotlin-stdlib:2.4.10`: the root ext `kotlinVersion = "2.4.10"` had been feeding third-party RN
libraries their stdlib version, poisoning them with metadata the 2.2.10 compiler cannot read. The
suppression had been covering both at once.

## Chosen direction: (b), lower the SDK, with the reason

The published-library rule decides it: a library is built with the oldest compiler its consumers
use, because newer compilers read older metadata, never the reverse. The floor consumer is the
RN 0.87 app at compiler 2.2.10, which this app cannot re-pin (the versionless classpath inherits
from RN's included build and AGP; raising `kotlinVersion` demonstrably does not change the
compiler and demonstrably does poison third-party stdlibs). Direction (a) would also push the
same override onto every third-party RN 0.87 app that consumes `@hop-mesh/react-native`, and
would compile RN 0.87 code with a compiler RN has not tested.

`sdk/android` moves to `kotlin("jvm") version "2.2.10"`, exactly the patch the RN build runs. The
published coordinate stays `sh.hop:hop:0.0.5`; the version line is untouched.

What I checked for the other consumers:
- `bearers/android`: compiles the shared `sdk/android` sources through its `:hop-sdk` JVM shim at
  its own 2.4.10 pin (`bearers/android/build.gradle.kts:7`), not the AAR metadata. Verified:
  `./gradlew :hop-sdk:compileKotlin` BUILD SUCCESSFUL after the change.
- `apps/android/HopDemo`: same shim pattern, own 2.4.10 pin
  (`apps/android/HopDemo/build.gradle.kts:4-5`). Verified: `./gradlew :hop-sdk:compileKotlin`
  BUILD SUCCESSFUL after the change.
- `drivers/android`: uses UniFFI-generated bindings, not the `sh.hop:hop` AAR. Unaffected.
- `tools/package-export-smoke.py` generated consumer: Kotlin 2.4.0, reads metadata 2.2.0 fine.
- `apps/ble-lab/android`: its own `sh.hopme.*` namespace, not an SDK consumer. Unaffected.

## Evidence

Suppression deleted; nothing in the tree adds it:

```
$ git grep -n 'skip-metadata-version-check'
(no matches in tracked files)
```

The republished AAR's metadata, decoded from `classes.jar`'s `META-INF/hop-kotlin.kotlin_module`
(4-byte big-endian version triple):

```
rebuilt, KGP 2.2.10: [2, 2, 0]
old,     KGP 2.4.10: [2, 4, 0]   (from the Gradle transform cache copy)
```

The green build consumed the rebuilt artifact (transform `bfce048e`, metadata [2,2,0]; compiling
against the [2,4,0] jar would be impossible without the flag):

```
$ cd apps/react-native/HopDemo/android && ./gradlew :app:assembleDebug
BUILD SUCCESSFUL in 24s
```

Native libraries in the APK, `unzip -l app/build/outputs/apk/debug/app-debug.apk`:

| abi | libhop.so | libjnidispatch.so |
|---|---|---|
| arm64-v8a | present | present |
| armeabi-v7a | present | present |
| x86 | present | present |
| x86_64 | present | present |

`libjnidispatch.so` is JNA arriving transitively through the AAR's POM, so the dependency chain
survived the republish.

`sdk/android` itself at 2.2.10: `gradle compileKotlin` and `gradle test` (JVM suite against a real
host libhop) both green, Gradle 9.7.0 locally; CI's kotlin-sdk job runs the same tests at Gradle
8.9.

## Files

- `apps/react-native/HopDemo/android/build.gradle`: suppression block deleted; `kotlinVersion`
  ext corrected to 2.2.10 with the measured mechanism documented; the old comment's incorrect
  explanation is called out as wrong.
- `sdk/android/build.gradle.kts`: Kotlin 2.4.10 -> 2.2.10 with the consumer-floor rationale.
- `apps/react-native/HopDemo/README.md`: Notes updated to the aligned state.
