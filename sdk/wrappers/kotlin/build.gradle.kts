// Hop Kotlin SDK — the idiomatic Kotlin/JVM face of libhop (via JNA). On Android this same code loads
// the libhop .so; this standalone JVM build lets the host smoke-test the wrapper against the dylib.
plugins {
    kotlin("jvm") version "2.0.21"
    application
}

repositories { mavenCentral() }

dependencies {
    implementation("net.java.dev.jna:jna:5.14.0")
}

application {
    mainClass.set("sh.hop.SmokeKt")
}

// Where JNA finds libhop_ffi.{dylib,so} — passed by smoke.sh via HOP_LIBDIR.
tasks.named<JavaExec>("run") {
    System.getenv("HOP_LIBDIR")?.let { systemProperty("jna.library.path", it) }
}

kotlin { jvmToolchain(17) }
