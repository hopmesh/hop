plugins {
    id("com.android.application") version "9.4.0" apply false
    id("com.android.library") version "9.4.0" apply false
    id("org.jetbrains.kotlin.android") version "2.4.10" apply false
    id("org.jetbrains.kotlin.jvm") version "2.4.10" apply false   // :hop-sdk (the sh.hop java-library)
    // Kotlin 2.0+ moved the Jetpack Compose compiler out of the Kotlin compiler distribution + AGP's
    // composeOptions.kotlinCompilerExtensionVersion wiring and into this standalone Gradle plugin, pinned
    // to the Kotlin version. Applied (with a version) only in :app, the one module with @Composable code.
    id("org.jetbrains.kotlin.plugin.compose") version "2.4.10" apply false
}
