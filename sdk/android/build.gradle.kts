// Hop Kotlin SDK — the idiomatic Kotlin/JVM face of libhop (via JNA). On Android this same code loads
// the libhop .so; this standalone JVM build lets the host smoke-test the wrapper against the dylib.
plugins {
    kotlin("jvm") version "2.4.0"
    application
    jacoco
}

repositories { mavenCentral() }

dependencies {
    implementation("net.java.dev.jna:jna:5.19.1")
    // F-34: radio-free unit tests for the transport multiplexer (BearerManager), replacing the
    // registry tests lost when the old HopBearers package was superseded.
    testImplementation(kotlin("test"))
}

tasks.test {
    useJUnitPlatform()
    // Where JNA finds libhop.{dylib,so} for the native integration tests (mirrors the `run` task):
    // HOP_LIBDIR in CI, otherwise the in-repo target/debug. Tests that touch the lib skip themselves
    // (assumeLibhop) when it isn't present, so `gradle test` still runs the pure-Kotlin suite alone.
    systemProperty(
        "jna.library.path",
        System.getenv("HOP_LIBDIR")
            ?: layout.projectDirectory.dir("../../target/debug").asFile.absolutePath,
    )
    finalizedBy(tasks.named("jacocoTestReport"))
}

// Smoke.kt is the libhop smoke harness (application main + a loopback bearer that drives two live
// nodes). Its classes are excluded from the coverage denominator in BOTH the report and the gate;
// the same code paths are covered by HopNodeIntegrationTest / HopRuntimeIntegrationTest instead.
val smokeCoverageExcludes = listOf("sh/hop/SmokeKt.class", "sh/hop/Smoke*.class", "sh/hop/LoopbackBearer*.class")

// quality-cov: line-coverage report for the Kotlin SDK surface (Hop.kt / Transport.kt / Bearers.kt).
tasks.named<JacocoReport>("jacocoTestReport") {
    dependsOn(tasks.test)
    reports {
        xml.required.set(true)
        html.required.set(true)
    }
    classDirectories.setFrom(
        files(classDirectories.files.map { fileTree(it) { exclude(smokeCoverageExcludes) } }),
    )
}

// cov/kotlin: lock the grade. Fail the build if line coverage of the SDK surface (now including the
// JNA/native HopNode layer) drops below 80%. Reaching it needs libhop present, so CI builds the lib
// and passes HOP_LIBDIR before invoking this task; it is deliberately NOT wired into `check` so a
// plain local `gradle build` (no lib) doesn't fail on the skipped native tests.
tasks.named<JacocoCoverageVerification>("jacocoTestCoverageVerification") {
    dependsOn(tasks.test)
    classDirectories.setFrom(
        files(classDirectories.files.map { fileTree(it) { exclude(smokeCoverageExcludes) } }),
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

application {
    mainClass.set("sh.hop.SmokeKt")
}

// Where JNA finds libhop.{dylib,so} — passed by smoke.sh via HOP_LIBDIR.
tasks.named<JavaExec>("run") {
    System.getenv("HOP_LIBDIR")?.let { systemProperty("jna.library.path", it) }
}

kotlin { jvmToolchain(17) }
