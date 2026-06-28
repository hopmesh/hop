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
rootProject.name = "BleLab"
// One core lib + one lib per bearer (NO master lib): mirrors apple/HopBearers' package structure.
// :bearer-wifidirect is Android-only (no Apple counterpart — iOS has no Wi-Fi Direct).
include(":bearer-core", ":bearer-ble", ":bearer-lan", ":bearer-wifidirect", ":app")
