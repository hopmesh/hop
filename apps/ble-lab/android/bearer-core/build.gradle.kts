import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

// :bearer-core, the transport-agnostic CORE of the bearer layer (Android mirror of
// apple/HopBearers' HopBearerCore). There is NO master library: this core holds only the
// Bearer/LinkSink contract, the BearerManager registry, the shared nodeId helpers, and the grep-able
// log/hex utilities. Each transport is its OWN library (`:bearer-ble`, `:bearer-lan`, …) that depends
// only on this core, a BLE-only build never links LAN code. This file names NOTHING transport-specific.
android {
    namespace = "sh.hopme.bearers"
    compileSdk = 34

    defaultConfig {
        minSdk = 29 // matches the BLE transport (L2CAP CoC requires API 29+); one minSdk across the layer
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }
}
kotlin { compilerOptions { jvmTarget.set(JvmTarget.JVM_1_8) } }

dependencies {
    // Intentionally zero third-party deps: the contract + registry are pure Kotlin/JVM.
}
