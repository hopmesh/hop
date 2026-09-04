import org.gradle.api.tasks.bundling.Jar
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

// Hop for Compose Multiplatform. A UI-layer SDK: the reactive HopClient, the pure state reducer, and the
// Compose composables all live in commonMain and target Android, Desktop (JVM), and iOS from one source.
// The only platform code is the wall-clock actual (Clock.*.kt) and the JVM engine adapter (JnaHopEngine,
// shared by android + desktop via the jvmShared source set). iOS supplies its engine from the app over
// the Apple xcframework. See CLAUDE.md for the layering.
plugins {
    kotlin("multiplatform") version "2.4.10"
    id("org.jetbrains.kotlin.plugin.compose") version "2.4.10"
    id("org.jetbrains.compose") version "1.12.0"
    id("com.android.library") version "9.4.0"
    `maven-publish`
}

group = "sh.hop"
version = "0.0.1"

kotlin {
    androidTarget {
        publishLibraryVariants("release")
        compilerOptions { jvmTarget.set(JvmTarget.JVM_17) }
    }
    jvm("desktop") {
        compilerOptions { jvmTarget.set(JvmTarget.JVM_17) }
    }
    iosX64()
    iosArm64()
    iosSimulatorArm64()

    // Default hierarchy gives commonMain, iosMain (shared across the three ios targets), androidMain,
    // and desktopMain. We add ONE custom intermediate, jvmShared, so the JVM wall-clock actual is written
    // once and shared by android + desktop. The library depends ONLY on public artifacts (Compose
    // Multiplatform + coroutines): the node bindings stay behind the app-supplied HopEngine seam, so
    // nothing here pulls an unpublished native SDK onto the classpath. See examples/jvm/JnaHopEngine.kt.
    applyDefaultHierarchyTemplate()

    sourceSets {
        val commonMain by getting {
            dependencies {
                implementation(compose.runtime)
                implementation(compose.foundation)
                implementation(compose.material3)
                implementation(compose.ui)
                implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.11.0")
            }
        }
        val commonTest by getting {
            dependencies {
                implementation(kotlin("test"))
                implementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.11.0")
            }
        }
        val jvmSharedMain by creating { dependsOn(commonMain) }
        val androidMain by getting { dependsOn(jvmSharedMain) }
        val desktopMain by getting { dependsOn(jvmSharedMain) }
        // iosMain is provided by the default hierarchy template.
    }
}

android {
    namespace = "sh.hop.compose"
    compileSdk = 36
    defaultConfig { minSdk = 24 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

// Maven Central REQUIRES a -javadoc.jar beside every published artifact, and the Kotlin Multiplatform
// plugin only generates the sources jars. Without this the deployment is rejected at validation, after
// the tag has already been cut. So attach one javadoc jar to every publication (the root
// kotlinMultiplatform module plus each target), the same README+LICENSE stand-in sdk/android publishes.
val javadocJar by tasks.registering(Jar::class) {
    archiveClassifier.set("javadoc")
    from("README.md", "LICENSE.md")
}

publishing {
    publications.withType<MavenPublication>().configureEach {
        artifact(javadocJar)
        pom {
            name.set("Hop for Compose Multiplatform")
            description.set(
                "Reactive client and Compose Multiplatform UI for the Hop mesh: one codebase renders " +
                    "a mesh messenger on Android, Desktop, and iOS over the libhop C ABI.",
            )
            url.set("https://hopme.sh")
            licenses {
                license {
                    name.set("Apache License, Version 2.0")
                    url.set("https://www.apache.org/licenses/LICENSE-2.0.txt")
                }
            }
            developers {
                developer {
                    id.set("hopmesh")
                    name.set("Hop Mesh, LLC")
                    url.set("https://hopme.sh")
                }
            }
        }
    }
    repositories {
        maven {
            name = "hop"
            url = uri(
                providers.gradleProperty("hopMavenRepository")
                    .getOrElse(layout.buildDirectory.dir("maven-repository").get().asFile.absolutePath),
            )
        }
    }
}
