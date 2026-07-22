plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

// :bearer-lan, the LAN transport as its OWN library (Android mirror of apple/HopBearers' HopBearerLan).
// Two devices on the same Wi-Fi/LAN discover each other over NSD/Bonjour (`_hoplan._tcp`) and talk over
// TCP. Depends ONLY on :bearer-core, and speaks the SAME link grammar (HELLO/PING/PONG/DATA over a
// 4-byte length prefix) as the Apple LanBearer so Android<->Apple interop. Names nothing about BLE.
android {
    namespace = "sh.hopme.bearers.lan"
    compileSdk = 34

    defaultConfig {
        minSdk = 29 // one minSdk across the bearer layer (NSD + TCP are available well below this)
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }
    kotlinOptions { jvmTarget = "1.8" }
}

dependencies {
    implementation(project(":bearer-core")) // the Bearer/LinkSink contract + nodeId/log helpers
    // Intentionally zero third-party deps: the transport is pure platform NSD + java.net sockets.
}
