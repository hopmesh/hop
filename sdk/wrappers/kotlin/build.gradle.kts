// Hop Kotlin SDK — the idiomatic Kotlin/JVM face of libhop (via JNA). On Android this same code loads
// the libhop .so; this standalone JVM build lets the host smoke-test the wrapper against the dylib.
plugins {
    kotlin("jvm") version "2.0.21"
    application
    jacoco
}

repositories { mavenCentral() }

dependencies {
    implementation("net.java.dev.jna:jna:5.14.0")
    // F-34: radio-free unit tests for the transport multiplexer (BearerManager), replacing the
    // registry tests lost when the old HopBearers package was superseded.
    testImplementation(kotlin("test"))
}

tasks.test {
    useJUnitPlatform()
    finalizedBy(tasks.named("jacocoTestReport"))
}

// quality-cov: line-coverage report for the pure Kotlin SDK surface (Hop.kt / Transport.kt /
// Bearers.kt). Smoke.kt is the libhop smoke harness (needs the native .so), so it is excluded from
// the denominator — the unit tests deliberately cover the radio-/native-free logic only.
tasks.named<JacocoReport>("jacocoTestReport") {
    dependsOn(tasks.test)
    reports {
        xml.required.set(true)
        html.required.set(true)
    }
    classDirectories.setFrom(
        files(classDirectories.files.map {
            fileTree(it) {
                // Smoke.kt is the libhop smoke harness (application main + a loopback bearer that drives
                // two live nodes), so it needs the native .so and is not radio-free-testable.
                exclude("sh/hop/SmokeKt.class", "sh/hop/Smoke*.class", "sh/hop/LoopbackBearer*.class")
            }
        }),
    )
}

application {
    mainClass.set("sh.hop.SmokeKt")
}

// Where JNA finds libhop.{dylib,so} — passed by smoke.sh via HOP_LIBDIR.
tasks.named<JavaExec>("run") {
    System.getenv("HOP_LIBDIR")?.let { systemProperty("jna.library.path", it) }
}

kotlin { jvmToolchain(17) }
