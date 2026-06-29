pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}
rootProject.name = "HopDemo"
include(":app", ":hop-driver", ":hop-sdk", ":bearer-ble", ":bearer-lan", ":bearer-wifidirect", ":bearer-relay")
// The app now consumes the re-homed bearer modules under bearers/android (each binds the Kotlin SDK
// `sh.hop`), plus :hop-sdk (the java-library wrapping the shared sh.hop source). projectDir points each
// at its real location so HopDemo uses the SAME isolated modules as the rest of the tree, no copies.
project(":hop-sdk").projectDir            = file("../../bearers/android/hop-sdk")
project(":bearer-ble").projectDir         = file("../../bearers/android/bearer-ble")
project(":bearer-lan").projectDir         = file("../../bearers/android/bearer-lan")
project(":bearer-wifidirect").projectDir  = file("../../bearers/android/bearer-wifidirect")
project(":bearer-relay").projectDir       = file("../../bearers/android/bearer-relay")
