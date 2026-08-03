// iOS engine wiring.
//
// Unlike the JVM targets, this SDK ships no bundled native engine for iOS: the Apple client node lives
// in the `sdk/apple` xcframework (Swift over the same libhop C ABI), which a Compose Multiplatform iOS
// app links directly. So on iOS you implement HopEngine as a small adapter over your app's Swift Hop
// node and pass it to `rememberHopClient(engine)`, exactly as the JVM app passes a JnaHopEngine.
//
// This is the seam working as intended: the UI SDK stays binding neutral, and each platform supplies the
// node it already has. The adapter is a handful of forwarding calls (address / tick / publishPrekey /
// send / pollInbox / statusOf), mirroring JnaHopEngine on the JVM side. A worked example lives in the
// README's "iOS" section. When the Apple SDK grows a cinterop-friendly C surface here, a bundled
// `AppleHopEngine` can replace the app-supplied adapter without changing anything above the seam.

package sh.hop.compose

/** Marker for the iOS source set. The engine itself is app-supplied on iOS (see the file header); this
 *  exists so the source set is non-empty and to give the README a stable symbol to point at. */
internal val IOS_ENGINE_IS_APP_SUPPLIED: Boolean = true
