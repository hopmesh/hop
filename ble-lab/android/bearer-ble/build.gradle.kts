plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

// :bearer-ble — the BLE transport as its OWN library (Android mirror of apple/HopBearers' HopBearerBle).
// Holds BleBearer (+ its internal Link / Peripheral / Central): the proven dual-role L2CAP transport,
// re-seamed behind the Bearer/LinkSink contract. Depends ONLY on :bearer-core. Names nothing about LAN.
android {
    namespace = "sh.hopme.bearers.ble"
    compileSdk = 34

    defaultConfig {
        minSdk = 29 // L2CAP CoC (listen/createInsecureL2capChannel) requires API 29+
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }
    kotlinOptions { jvmTarget = "1.8" }
}

dependencies {
    implementation(project(":bearer-core")) // the Bearer/LinkSink contract + nodeId/log helpers
    // Intentionally zero third-party deps: the transport is pure platform BLE.
}
