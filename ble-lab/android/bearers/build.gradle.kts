plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

// :bearers — the shared, transport-agnostic bearer layer (the Android mirror of apple/HopBearers).
// Holds the Bearer/LinkSink contract, the BearerManager registry, and BleBearer (the re-seamed
// dual-role BLE transport). The proof-of-pipe consumer (ProofSink) lives in the app, not here.
android {
    namespace = "net.waldrip.hop.bearers"
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
    // Intentionally zero third-party deps: the transport is pure platform BLE.
}
