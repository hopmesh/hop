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
    // The bearer layer as a core lib + one lib per transport (NO master lib), mirroring apple/HopBearers:
    //   :bearer-core — the Bearer/LinkSink contract, BearerManager registry, nodeId + log helpers
    //   :bearer-ble  — the dual-role L2CAP BLE transport      (depends on :bearer-core)
    //   :bearer-lan  — the NSD + TCP LAN transport            (depends on :bearer-core)
    // The app supplies only the clean-room ProofSink consumer and picks which bearers to register.
    implementation(project(":bearer-core"))
    implementation(project(":bearer-ble"))
    implementation(project(":bearer-lan"))
    // Intentionally zero third-party deps: the proof-of-pipe core is pure platform BLE + LAN.
}
