package sh.hopme.demo

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
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
        assertEquals("hops://example.hopme.sh", normalizeHops("HOPS://example.hopme.sh"))
    }

    @Test fun browserPolicyAllowsOnlyHopsAndLocalBootstrap() {
        assertTrue(browserAllowsURL("hops://example.hop/page"))
        assertTrue(browserAllowsURL("HOPS://EXAMPLE.HOP/page"))
        assertTrue(browserAllowsURL("about:blank"))
        assertTrue(browserAllowsURL("/image.png", relativeTo = "hops://example.hop/page"))
        assertTrue(browserAllowsURL("//other.hop/frame", relativeTo = "hops://example.hop/page"))
    }

    @Test fun browserPolicyDeniesTopLevelAndEveryActiveSubresourceScheme() {
        val blocked = listOf(
            "http://evil.test/", "HTTPS://evil.test/script.js", "ws://evil.test/socket",
            "WSS://evil.test/socket", "data:text/html,boom", "blob:hops://example.hop/id",
            "file:///etc/passwd", "content://authority/item", "intent://evil/#Intent;scheme=https;end",
            "javascript:alert(1)", "custom://evil/path",
        )
        for (url in blocked) assertFalse("must block $url", browserAllowsURL(url))
    }

    @Test fun browserPolicyRejectsCredentialsPortsOpaqueAndSchemeSmuggling() {
        val blocked = listOf(
            "hops://user@example.hop/", "hops://example.hop:443/", "hops:opaque",
            "hops://example.hop/#fragment", "hops://example.hop\\@evil.test/",
            "https:relative.js", "  //evil.test/x  ",
        )
        for (url in blocked) assertFalse("must block $url", browserAllowsURL(url))
    }

    @Test fun browserPolicyAppliesToScriptImageFrameFetchAndWebSocketForms() {
        val base = "hops://site.hop/index.html"
        for (relative in listOf("script.js", "./image.png", "../frame.html", "/api/fetch", "socket")) {
            assertTrue("relative hops resource $relative", browserAllowsURL(relative, relativeTo = base))
        }
        for (external in listOf(
            "https://cdn.test/script.js", "http://img.test/a.png", "data:text/html,<iframe>",
            "https://api.test/fetch", "wss://socket.test/chat",
        )) assertFalse("active resource must be blocked: $external", browserAllowsURL(external, relativeTo = base))
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

    @Test fun cappedAttachmentReadAcceptsBoundaryAndRejectsOneByteOver() {
        val boundary = ByteArray(16) { it.toByte() }
        assertEquals(boundary.toList(), readCapped(boundary.inputStream(), maximum = 16)?.toList())
        assertNull(readCapped(ByteArray(17).inputStream(), maximum = 16))
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

    // originStamp: when the ORIGINATING device sent it ------------------------------------------

    /** A fixed UTC zone, so these assert the format and never the runner's region. */
    private val utc = java.time.ZoneId.of("UTC")
    private fun at(y: Int, mo: Int, d: Int, h: Int, mi: Int): Long =
        java.time.ZonedDateTime.of(y, mo, d, h, mi, 0, 0, utc).toInstant().toEpochMilli()

    @Test fun origin_stamp_is_bare_time_for_today() {
        val now = at(2026, 7, 26, 21, 40)
        assertEquals("09:05", originStamp(at(2026, 7, 26, 9, 5), now, utc))
    }

    /**
     * The delay-tolerant case that makes this more than cosmetic: a bundle can arrive long after it
     * was sent, so a bare time on an old message would read as recent.
     */
    @Test fun origin_stamp_names_yesterday_and_older_days() {
        val now = at(2026, 7, 26, 21, 40)
        assertEquals("Yesterday 23:59", originStamp(at(2026, 7, 25, 23, 59), now, utc))
        assertEquals("20 Jul 08:00", originStamp(at(2026, 7, 20, 8, 0), now, utc))
        assertEquals("31 Dec 2025 23:15", originStamp(at(2025, 12, 31, 23, 15), now, utc))
    }

    /**
     * Yesterday is a CALENDAR day, not "within 24 hours": 00:10 today and 23:50 yesterday are 20
     * minutes apart but must not both render as a bare time.
     */
    @Test fun origin_stamp_yesterday_is_a_calendar_day_not_a_24h_window() {
        val now = at(2026, 7, 26, 0, 10)
        assertEquals("Yesterday 23:50", originStamp(at(2026, 7, 25, 23, 50), now, utc))
        assertEquals("00:00", originStamp(at(2026, 7, 26, 0, 0), now, utc))
    }

    @Test fun origin_stamp_never_shows_seconds_because_the_private_path_buckets_to_60s() {
        val now = at(2026, 7, 26, 12, 0)
        val withSeconds = java.time.ZonedDateTime.of(2026, 7, 26, 11, 30, 59, 0, utc).toInstant().toEpochMilli()
        assertEquals("11:30", originStamp(withSeconds, now, utc))
    }

    /** Incoming uses the sender's stamp; outgoing uses our own clock, since we ARE the origin. */
    @Test fun origin_label_picks_the_right_clock_per_direction_and_is_null_when_unstamped() {
        val t = at(2026, 7, 26, 10, 0)
        val incoming = HopBearer.Message(localId = 1, peer = "p", text = "hi", incoming = true,
            originAt = t, sentAt = at(2026, 7, 26, 18, 0))
        assertEquals("incoming must show the SENDER's stamp, not our receive time",
            originStamp(t, at(2026, 7, 26, 19, 0), java.time.ZoneId.systemDefault()),
            originLabel(incoming, at(2026, 7, 26, 19, 0)))

        val outgoing = HopBearer.Message(localId = 2, peer = "p", text = "yo", incoming = false,
            originAt = null, sentAt = t)
        assertEquals("outgoing falls back to our own send clock",
            originStamp(t, at(2026, 7, 26, 19, 0), java.time.ZoneId.systemDefault()),
            originLabel(outgoing, at(2026, 7, 26, 19, 0)))

        val unstamped = HopBearer.Message(localId = 3, peer = "p", text = "?", incoming = true, originAt = null)
        assertNull("an unstamped incoming message shows nothing rather than 1970",
            originLabel(unstamped, at(2026, 7, 26, 19, 0)))
    }
}
