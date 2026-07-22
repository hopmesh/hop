plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

// :bearer-relay, the cloud-relay transport as its OWN library (Android mirror of apple/HopBearers'
// HopBearerRelay). It is the SIMPLEST bearer: ONE outbound WebSocket to the backbone relay, no peer
// discovery, no HELLO, no length framing (a WS message already frames one node packet), no dedup.
// Depends ONLY on :bearer-core. Unlike the other bearer libs this has ONE third-party dep, OkHttp, the
// SAME version the production hop-driver already uses, for the WebSocket. (That is why ble-lab's own
// P2P clean room does NOT include this module: it keeps OkHttp out of the lab.) Names nothing about
// BLE/LAN; it is written purely against the Bearer/LinkSink contract.
android {
    namespace = "sh.hopme.bearers.relay"
    compileSdk = 34

    defaultConfig {
        minSdk = 29 // one minSdk across the bearer layer
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }
    kotlinOptions { jvmTarget = "1.8" }
}

dependencies {
    implementation(project(":bearer-core")) // the Bearer/LinkSink contract + nodeId/log helpers
    // Cloud relay WebSocket, the SAME OkHttp version the production hop-driver pins (its only dep).
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
}
