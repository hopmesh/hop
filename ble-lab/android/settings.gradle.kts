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
include(":bearer-core", ":bearer-ble", ":bearer-lan", ":app")
