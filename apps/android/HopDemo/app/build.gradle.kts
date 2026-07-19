import org.gradle.testing.jacoco.plugins.JacocoTaskExtension
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // Kotlin 2.0+ moved the Compose compiler out of AGP/kotlinCompilerExtensionVersion into this plugin
    // (version = the Kotlin version, above). Required for any module compiling @Composable code
    // (MainActivity.kt, DemoFormat.kt) under Kotlin 2.x.
    id("org.jetbrains.kotlin.plugin.compose")
    jacoco
}

// cov/android-demo: the demo app's non-UI helpers (DemoFormat.kt) + the crash handler (HopApp.kt) run
// under Robolectric, which re-defines the classes-under-test in its own sandbox classloader WITHOUT a
// source location. JaCoCo's on-the-fly agent SKIPS no-location classes by default, so without this the
// helpers execute under test but read as 0% covered. isIncludeNoLocationClasses = true makes the agent
// record them; the jdk.internal.* exclude avoids the JDK17 instrumentation crash the flag otherwise
// triggers. (Same fix the driver + bearers use.)
tasks.withType<Test>().configureEach {
    configure<JacocoTaskExtension> {
        isIncludeNoLocationClasses = true
        excludes = listOf("jdk.internal.*")
    }
}

// cov/android-demo: analyze with the SAME JaCoCo the AGP coverage agent embeds (0.8.11). A version skew
// between the agent that writes the .exec and the report task that reads it makes the Robolectric-loaded
// classes resolve to 0% (their exec class-ids don't line up), even though AGP's own report shows them
// covered. Pinning the tool version keeps the excluding report/gate honest.
jacoco { toolVersion = "0.8.11" }

android {
    namespace = "sh.hopme.demo"
    compileSdk = 37 // required by core-ktx 1.19.0's AAR metadata (>= 37 from every consumer)

    defaultConfig {
        applicationId = "sh.hopme.demo"
        minSdk = 29 // L2CAP CoC (createInsecureL2capChannel) requires API 29+
        targetSdk = 34
        versionCode = 1
        versionName = "0.1.0"
    }

    // android-r2-04: a hardened release variant. R8 minify + resource shrink, ProGuard rules that keep
    // only what UniFFI/JNA/OkHttp/Compose reflect on, and (via the merged manifest, below) no backup and
    // no exported automation deep link. BuildConfig.DEBUG is false here, so the driver's automation +
    // plaintext-mirror + verbose-log surfaces (android-r2-01/-03/-05) compile out of a release build.
    buildTypes {
        // quality-cov / cov/android-demo: JVM unit-test line coverage (AGP wires jacoco +
        // createDebugUnitTestCoverageReport and emits the .exec the report/gate tasks below read).
        getByName("debug") {
            enableUnitTestCoverage = true
        }
        getByName("release") {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    buildFeatures { compose = true; buildConfig = true }
    // composeOptions.kotlinCompilerExtensionVersion is gone as of Kotlin 2.0+ - the Compose compiler now
    // ships as the org.jetbrains.kotlin.plugin.compose Gradle plugin (applied above, pinned to the Kotlin
    // version), so there is nothing left to configure here.

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }

    // cov/android-demo: JVM unit tests for the pure helpers (DemoFormat.kt) + the crash handler
    // (HopApp.kt), run headless under Robolectric. isIncludeAndroidResources gives the merged R (so
    // transportIcon resolves real drawable ids) + a manifest for the Application host; returnDefaultValues
    // keeps any incidental android.jar stub call from throwing.
    testOptions {
        unitTests {
            isReturnDefaultValues = true
            isIncludeAndroidResources = true
        }
    }
}
// Kotlin 2.x makes `android.kotlinOptions { jvmTarget = ... }` a hard compile error (moved to
// compilerOptions); this is the direct replacement, one level up from the `android {}` block.
kotlin { compilerOptions { jvmTarget.set(JvmTarget.JVM_1_8) } }

dependencies {
    // The Hop runtime (bearer, transports, UniFFI bindings, native libs) lives in the driver.
    implementation(project(":hop-driver"))

    implementation(platform("androidx.compose:compose-bom:2026.06.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.11.0")
    // Matches :hop-driver (core-ktx must agree across the app's dependency graph); 1.19.0 unblocked by
    // the AGP 9.3 / compileSdk 37 toolchain alignment across both builds.
    implementation("androidx.core:core-ktx:1.19.0")

    // QR identity exchange: zxing core encodes our address to a QR; zxing-android-embedded is a
    // drop-in camera scanner to add a contact from someone else's QR.
    implementation("com.google.zxing:core:3.5.4")
    implementation("com.journeyapps:zxing-android-embedded:4.3.0")

    // cov/android-demo: the demo app's JVM unit tests. junit for assertions; Robolectric shadows the
    // Android framework (Context / File IO / Bitmap[+native graphics] / Log) so the DemoFormat helpers,
    // the QR/JPEG bitmap paths, and the HopApp crash handler run headless on the host - no device.
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.16.1")
    testImplementation("androidx.test:core:1.7.0")
}

// cov/android-demo: line-coverage report over the demo app's NON-UI, testable surface only:
//   - DemoFormatKt : the extracted pure helpers (platformLabel / transportIcon / makeQrBitmap /
//                    jpegDownscale / messageMeta / normalizeHops / statusText).
//   - HopApp       : the process-wide uncaught-exception crash logger (Application).
// Everything else in the module is the Jetpack Compose UI + Activity/permission/camera/zxing-scan code,
// which is UI/device-bound and excluded from the denominator (see demoCoverageClassDirs). Reads the exec
// that AGP's enableUnitTestCoverage produces from testDebugUnitTest.
tasks.register<JacocoReport>("jacocoDemoReport") {
    dependsOn("testDebugUnitTest")
    reports {
        xml.required.set(true)
        html.required.set(true)
    }
    classDirectories.setFrom(demoCoverageClassDirs())
    sourceDirectories.setFrom(files("src/main/java"))
    executionData.setFrom(
        fileTree(buildDir) { include("outputs/unit_test_code_coverage/debugUnitTest/testDebugUnitTest.exec") },
    )
}

// cov/android-demo: the demo app's product classes that count toward coverage. The exclusions are all
// principled UI/device-bound code that is NOT unit-testable on the JVM, mirroring the driver's uniffi/**
// + KeystoreSecret exclusions and the iOS app's device-radio exclusions:
//   - **/MainActivity*         : the ComponentActivity + EVERY @Composable screen render body
//                                (MainActivityKt), plus the permission-request/settings-deep-link and
//                                the camera/zxing-scan launchers. Compose render bodies are UI-bound and
//                                brittle under Robolectric (the least reliable lane); the Activity +
//                                permission + camera paths are genuinely device-bound. Verified instead
//                                by the on-device / cross-platform workflow (testkit + real devices).
//   - **/ComposableSingletons* : Compose-generated lambda singletons for those screens (pure UI glue).
//   - **/BuildConfig*          : generated constants, no logic.
fun demoCoverageClassDirs() = fileTree("${buildDir}/tmp/kotlin-classes/debug") {
    exclude("**/MainActivity*")
    exclude("**/ComposableSingletons*")
    exclude("**/BuildConfig*")
}

// cov/android-demo: hard 80% LINE floor over the same denominator as the report. Invoked from the
// `android` CI job so the demo app's grade is ENFORCED (previously the module had no test source set and
// no coverage task at all). Fails the build if covered lines of the testable surface drop below 80%.
tasks.register<JacocoCoverageVerification>("jacocoDemoCoverageVerification") {
    dependsOn("testDebugUnitTest")
    classDirectories.setFrom(demoCoverageClassDirs())
    sourceDirectories.setFrom(files("src/main/java"))
    executionData.setFrom(
        fileTree(buildDir) { include("outputs/unit_test_code_coverage/debugUnitTest/testDebugUnitTest.exec") },
    )
    violationRules {
        rule {
            limit {
                counter = "LINE"
                value = "COVEREDRATIO"
                minimum = "0.80".toBigDecimal()
            }
        }
    }
}
