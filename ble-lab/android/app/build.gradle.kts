plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "net.waldrip.blelab"
    compileSdk = 34

    defaultConfig {
        applicationId = "net.waldrip.blelab"
        minSdk = 29 // L2CAP CoC (listen/createInsecureL2capChannel) requires API 29+
        targetSdk = 34
        versionCode = 1
        versionName = "0.1.0"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }
    kotlinOptions { jvmTarget = "1.8" }
}

dependencies {
    // Intentionally zero third-party deps: the proof-of-pipe core is pure platform BLE.
}
