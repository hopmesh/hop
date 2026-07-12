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
// Wi-Fi Direct was removed from production (commit c059d69) and from this rig to match.
include(":bearer-core", ":bearer-ble", ":bearer-lan", ":app")
