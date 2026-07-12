package sh.hopme.demo

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import sh.hopme.driver.HopBearer

/**
 * cov/android-demo: the pure, non-UI helpers extracted from MainActivity.kt into DemoFormat.kt.
 * platformLabel / transportIcon / normalizeHops / statusText are host-pure; messageMeta formats a
 * HopBearer.Message (a plain data class) via the driver's pure companion helpers (hopsLabel /
 * compactDuration). Runs under Robolectric so transportIcon resolves the merged R drawable ids.
 */
@RunWith(RobolectricTestRunner::class)
class DemoFormatTest {

    @Test fun platformLabel_mapsKnownAndPassesThroughUnknown() {
        assertEquals("iOS", platformLabel("ios"))
        assertEquals("Android", platformLabel("android"))
        assertEquals("linux", platformLabel("linux")) // unknown -> passthrough
        assertEquals("", platformLabel(""))
    }

    @Test fun transportIcon_nonNullForKnownTags() {
        assertNotNull(transportIcon("BT"))
        assertNotNull(transportIcon("LAN"))
        assertNotNull(transportIcon("P2P"))
        assertNotNull(transportIcon("Relay"))
    }

    @Test fun transportIcon_distinctPerTag() {
        val ids = listOf("BT", "LAN", "P2P", "Relay").map { transportIcon(it) }
        assertEquals("each transport maps to a distinct drawable", ids.size, ids.toSet().size)
    }

    @Test fun transportIcon_nullForUnknownTags() {
        assertNull(transportIcon("nope"))
        assertNull(transportIcon(""))
        assertNull(transportIcon("bt")) // case-sensitive
    }

    @Test fun normalizeHops_keepsExplicitHopsScheme() {
        assertEquals("hops://example.hopme.sh", normalizeHops("hops://example.hopme.sh"))
        assertEquals("hops://example.hopme.sh", normalizeHops("  hops://example.hopme.sh  ")) // trims
    }

    @Test fun normalizeHops_reschemesHttpAndBareHost() {
        assertEquals("hops://example.hopme.sh", normalizeHops("https://example.hopme.sh"))
        assertEquals("hops://example.hopme.sh", normalizeHops("http://example.hopme.sh"))
        assertEquals("hops://example.hopme.sh", normalizeHops("example.hopme.sh"))
    }

    @Test fun statusText_knownCodesAndFallback() {
        assertEquals("OK", statusText(200))
        assertEquals("Not Found", statusText(404))
        assertEquals("Bad Gateway", statusText(502))
        assertEquals("Unavailable", statusText(503))
        assertEquals("Timeout", statusText(504))
        assertEquals("Status", statusText(418)) // fallback
    }

    // --- messageMeta: every branch -------------------------------------------------------------

    private fun msg(
        incoming: Boolean = false,
        hops: UByte = 0u,
        latencyMs: ULong? = null,
        trace: List<String> = emptyList(),
        delivered: Boolean = false,
        deliveryHops: UByte = 0u,
        deliveryMs: ULong? = null,
        failed: Boolean = false,
        relayed: UInt = 0u,
    ) = HopBearer.Message(
        localId = 1L, peer = "peer", text = "hi", incoming = incoming,
        hops = hops, latencyMs = latencyMs, trace = trace,
        delivered = delivered, deliveryHops = deliveryHops, deliveryMs = deliveryMs,
        failed = failed, relayed = relayed,
    )

    @Test fun messageMeta_incomingDirectWithLatencyAndTrace() {
        val s = messageMeta(msg(incoming = true, hops = 1u, latencyMs = 3_000uL, trace = listOf("a", "b")))
        assertEquals("direct, 3s  ·  via a → b", s)
    }

    @Test fun messageMeta_incomingMultiHopNoLatencyNoTrace() {
        assertEquals("3 hops", messageMeta(msg(incoming = true, hops = 3u)))
    }

    @Test fun messageMeta_incomingWithLatencyNoTrace() {
        assertEquals("direct, 5m", messageMeta(msg(incoming = true, hops = 1u, latencyMs = 300_000uL)))
    }

    @Test fun messageMeta_deliveredReportsForwardHopsAndDuration() {
        val s = messageMeta(msg(delivered = true, deliveryHops = 2u, deliveryMs = 5_000uL))
        assertEquals("Delivered, 2 hops, 5s", s)
    }

    @Test fun messageMeta_deliveredWithNullDurationCoercesToZero() {
        val s = messageMeta(msg(delivered = true, deliveryHops = 1u, deliveryMs = null))
        assertEquals("Delivered, direct, 0s", s)
    }

    @Test fun messageMeta_failedIsNotSent() {
        assertEquals("Not sent", messageMeta(msg(failed = true)))
    }

    @Test fun messageMeta_sentSingularPeer() {
        assertEquals("Sent · 1 peer", messageMeta(msg(relayed = 1u)))
    }

    @Test fun messageMeta_sentPluralPeers() {
        assertEquals("Sent · 0 peers", messageMeta(msg(relayed = 0u)))
        assertEquals("Sent · 2 peers", messageMeta(msg(relayed = 2u)))
    }
}
