plugins {
    id("org.jetbrains.kotlin.jvm")
    `java-library`
}
// The Kotlin SDK (sh.hop) compiled as a plain JVM library so Android bearer modules can depend on it.
// It is a BUILD-TIME shim with no sources of its own; it never publishes (the bearers' POMs name the
// published `sh.hop:hop` AAR instead, see the publishing convention in the root build).
//
// SHARED SOURCE. It compiles the SHARED source under sdk/android (one source of truth, no copy). That
// path is OUTSIDE `bearers/android`, so the shim used to detect which tree it was in and fall back to
// the published SDK artifact when the subtree was exported to a public mirror without it. That mirror is
// retired, so the shared source is always on disk and the fallback is gone.
sourceSets["main"].java.srcDir(file("../../../sdk/android/src/main/kotlin"))
kotlin { jvmToolchain(17) }
dependencies {
    // JNA is provided by the app (as the Android @aar, for UniFFI); compileOnly avoids a jar+aar clash.
    compileOnly("net.java.dev.jna:jna:5.19.1")
}
