# android-r2-04: R8 rules for the hardened release variant.
#
# UniFFI-generated bindings load libhop via JNA and cross the JNI boundary reflectively, so the
# generated bindings package, JNA's runtime, and the native-callback types must survive shrinking or
# the FFI call sites resolve to nothing at runtime.

# UniFFI Kotlin bindings (uniffi.hop.*), reflected across the FFI boundary.
-keep class uniffi.hop.** { *; }
-keep class uniffi.** { *; }

# JNA: uses reflection + native method binding; strip it and every native call NPEs.
-keep class com.sun.jna.** { *; }
-keepclassmembers class * extends com.sun.jna.** { *; }
-keep class * implements com.sun.jna.** { *; }
-dontwarn java.awt.**

# OkHttp / Okio (cloud relay bearer): keep public surface, silence optional deps.
-dontwarn okhttp3.**
-dontwarn okio.**
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**

# zxing (QR encode + embedded scanner).
-keep class com.google.zxing.** { *; }
-keep class com.journeyapps.barcodescanner.** { *; }

# Kotlin metadata for reflection-friendly libraries.
-keepattributes *Annotation*, InnerClasses, Signature, EnclosingMethod
