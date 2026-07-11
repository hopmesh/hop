package sh.hop

import java.io.File
import org.junit.jupiter.api.Assumptions.assumeTrue

// cov/kotlin: shared scaffolding for the JNA/native integration tests. Those tests only make sense
// when a real libhop is on the JNA search path (the `test` task sets jna.library.path from HOP_LIBDIR,
// falling back to the in-repo target/debug). When the lib isn't built they skip via assumeLibhop() so
// the pure-Kotlin suite still runs; CI builds the lib first, so the native surface is exercised there.

/** True iff a libhop platform library sits in one of the jna.library.path directories. */
internal fun libhopPresent(): Boolean {
    val path = System.getProperty("jna.library.path") ?: return false
    val names = listOf("libhop.dylib", "libhop.so", "hop.dll")
    return path.split(File.pathSeparatorChar).any { dir ->
        dir.isNotEmpty() && names.any { File(dir, it).exists() }
    }
}

/** Skip (not fail) a native test when libhop isn't built. Call FIRST, before touching HopNode. */
internal fun assumeLibhop() =
    assumeTrue(libhopPresent(), "libhop not on jna.library.path (build the lib / set HOP_LIBDIR)")

/**
 * Two live HopNodes wired by a direct in-memory loopback (A's outbound == B's inbound on link 1),
 * lifted from Smoke.kt. [handshake] runs the prekey/Noise warm-up; [pump] shuttles bytes and ticks.
 */
internal class DirectLoopback(val a: HopNode, val b: HopNode) {
    var now = 1_700_000_000_000L

    fun handshake() {
        a.tick(now); b.tick(now)
        a.publishPrekey(); b.publishPrekey()
        a.linkUp(1, HopRole.DIALER); b.linkUp(1, HopRole.ACCEPTOR)
        pump(50)
    }

    fun pump(rounds: Int, done: () -> Boolean = { false }): Boolean {
        repeat(rounds) {
            a.drainOutgoing { _, bytes -> b.bytesReceived(1, bytes) }
            b.drainOutgoing { _, bytes -> a.bytesReceived(1, bytes) }
            now += 100; a.tick(now); b.tick(now)
            if (done()) return true
        }
        return done()
    }
}
