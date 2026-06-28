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
include(":app", ":hop-driver", ":bearer-core", ":bearer-ble", ":bearer-lan", ":bearer-wifidirect")
// The shared cross-platform bearer modules physically live in ble-lab/ (NOT moved) — point each
// projectDir at its real location so HopDemo consumes the SAME sources the clean-room lab proved,
// without duplicating code. (From android/HopDemo, ../../ble-lab/android/... reaches them.)
project(":bearer-core").projectDir        = file("../../ble-lab/android/bearer-core")
project(":bearer-ble").projectDir         = file("../../ble-lab/android/bearer-ble")
project(":bearer-lan").projectDir         = file("../../ble-lab/android/bearer-lan")
project(":bearer-wifidirect").projectDir  = file("../../ble-lab/android/bearer-wifidirect")
