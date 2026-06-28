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
include(":app", ":hop-driver", ":bearer-core", ":bearer-ble", ":bearer-lan", ":bearer-wifidirect", ":bearer-relay")
// The shared cross-platform bearer modules physically live in ble-lab/ (NOT moved) — point each
// projectDir at its real location so HopDemo consumes the SAME sources the clean-room lab proved,
// without duplicating code. (From android/HopDemo, ../../ble-lab/android/... reaches them.)
// :bearer-relay is consumed ONLY here (HopDemo), NOT by ble-lab's own settings — that keeps OkHttp out
// of the P2P clean room while the production driver still gets the relay as a shared bearer.
project(":bearer-core").projectDir        = file("../../ble-lab/android/bearer-core")
project(":bearer-ble").projectDir         = file("../../ble-lab/android/bearer-ble")
project(":bearer-lan").projectDir         = file("../../ble-lab/android/bearer-lan")
project(":bearer-wifidirect").projectDir  = file("../../ble-lab/android/bearer-wifidirect")
project(":bearer-relay").projectDir       = file("../../ble-lab/android/bearer-relay")
