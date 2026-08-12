pluginManagement {
    repositories { google(); mavenCentral(); gradlePluginPortal() }
}
dependencyResolutionManagement {
    repositories { google(); mavenCentral() }
}
rootProject.name = "HopBearersAndroid"
// The Kotlin SDK (sh.hop) as a JVM lib + one isolated module per Android bearer (mirrors bearers/apple).
include(":hop-sdk", ":bearer-ble", ":bearer-lan", ":bearer-relay", ":bearer-meshtastic")
// The driver lives at drivers/android/hop-driver (north-star), built as part of this gradle build. The
// include used to be conditional because that path is OUTSIDE `bearers/android`, the subtree that was
// exported to a public mirror where it did not exist, and an unconditional include would fail settings
// evaluation there before any task could run. That mirror is retired, so the directory is always on
// disk and the include is unconditional.
include(":hop-driver")
project(":hop-driver").projectDir = file("../../drivers/android/hop-driver")
