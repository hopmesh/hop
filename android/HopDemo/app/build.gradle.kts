plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "sh.hopme.demo"
    compileSdk = 34

    defaultConfig {
        applicationId = "sh.hopme.demo"
        minSdk = 29 // L2CAP CoC (createInsecureL2capChannel) requires API 29+
        targetSdk = 34
        versionCode = 1
        versionName = "0.1.0"
    }

    buildFeatures { compose = true }
    composeOptions { kotlinCompilerExtensionVersion = "1.5.14" }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }
    kotlinOptions { jvmTarget = "1.8" }
}

dependencies {
    // The Hop runtime (bearer, transports, UniFFI bindings, native libs) lives in the driver.
    implementation(project(":hop-driver"))

    implementation(platform("androidx.compose:compose-bom:2024.06.00"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.activity:activity-compose:1.9.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.0")
    implementation("androidx.core:core-ktx:1.13.1")

    // QR identity exchange: zxing core encodes our address to a QR; zxing-android-embedded is a
    // drop-in camera scanner to add a contact from someone else's QR.
    implementation("com.google.zxing:core:3.5.3")
    implementation("com.journeyapps:zxing-android-embedded:4.3.0")
}
