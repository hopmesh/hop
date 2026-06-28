plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

// :bearer-wifidirect — the Wi-Fi Direct (Wi-Fi P2P) transport as its OWN library (Android-only; there is
// no Apple HopBearers equivalent — iOS has no Wi-Fi Direct). Two Android devices with NO shared
// network/router form a peer-to-peer group over Wi-Fi P2P and then talk plain TCP. Depends ONLY on
// :bearer-core and speaks the SAME link grammar (HELLO/PING/PONG/DATA over a 4-byte length prefix) as
// :bearer-lan, so the consumer sees identical linkUp/linkBytes/linkDown semantics regardless of radio.
// Per "each bearer its own lib" the framing is DUPLICATED here (not shared with :bearer-lan) — the two
// libs only agree on the wire bytes, not on code. Names nothing about BLE or LAN.
android {
    namespace = "net.waldrip.hop.bearers.wifidirect"
    compileSdk = 34

    defaultConfig {
        minSdk = 29 // one minSdk across the bearer layer (Wi-Fi P2P + TCP are available well below this)
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }
    kotlinOptions { jvmTarget = "1.8" }
}

dependencies {
    implementation(project(":bearer-core")) // the Bearer/LinkSink contract + nodeId/log helpers
    // Intentionally zero third-party deps: the transport is pure platform Wi-Fi P2P + java.net sockets.
}
