package sh.hopme.driver

import org.junit.Assert.assertTrue
import org.junit.Test

/** cov/android-driver: the BearerManager -> node seam (bearerSink). A link coming up / carrying bytes /
 *  going down is normally driven by a real radio; here we fire the same LinkSink callbacks directly with
 *  synthetic events so node.connected/received/disconnected + the per-link counters are exercised. */
class HopBearerLinkSinkTest : DriverTestBase() {

    private fun sink(): sh.hop.LinkSink =
        HopBearer::class.java.getDeclaredField("bearerSink").apply { isAccessible = true }.get(bearer) as sh.hop.LinkSink

    @Test fun linkUpBytesDownDriveTheNode() {
        val s = sink()
        val link = 1_000_000L
        s.linkUp(link, sh.hop.HopRole.DIALER, ByteArray(16) { 1 })
        settle()
        assertTrue("node saw the connection", fake.connectedLinks.contains(link.toULong()))

        s.linkBytes(link, byteArrayOf(1, 2, 3, 4))
        settle()
        assertTrue("bytes forwarded to node.received", fake.received.any { it.first == link.toULong() })

        s.linkDown(link)
        settle()
        assertTrue("node saw the disconnect", fake.disconnectedLinks.contains(link.toULong()))
    }

    @Test fun acceptorRoleIsNotADialer() {
        val s = sink()
        s.linkUp(1_000_042L, sh.hop.HopRole.ACCEPTOR, ByteArray(16) { 2 })
        settle()
        assertTrue(fake.connectedLinks.contains(1_000_042uL))
    }


    private class DummyBearer(override val transportName: String = "Dummy") : sh.hop.Bearer {
        override var sink: sh.hop.LinkSink? = null
        val closedLinks = mutableListOf<Long>()
        val authenticatedLinks = mutableListOf<Long>()
        override fun start() {}
        override fun stop() {}
        override fun send(bytes: ByteArray, link: Long) {}
        override fun close(link: Long) { closedLinks.add(link) }
        override fun authenticated(link: Long) { authenticatedLinks.add(link) }
    }

    @Test fun testNoiseXXAuthenticatedLinkSurvivesPreauthDeadlineWithoutDoubleRatchetSession() {
        val mgr = bearer.bearerMgr
        val dummy = DummyBearer()
        mgr.register(dummy)

        val alice = ByteArray(32) { 0x41 }
        val bob = ByteArray(32) { 0x42 }

        // Establish unauthenticated links on dummy bearer
        dummy.sink?.linkUp(101L, sh.hop.HopRole.ACCEPTOR, alice)
        dummy.sink?.linkUp(102L, sh.hop.HopRole.ACCEPTOR, bob)
        settle()

        // Simulate Noise XX completion for link 101 (global link 1_000_000):
        // Link is present in peerLinksList, but NOT in securedAddrs (no Double Ratchet session)
        fake.peerLinksList = listOf(uniffi.hop.PeerLink(address = alice, link = 1_000_000uL))
        fake.securedAddrs = emptySet()

        // Start bearer to run tick loop which polls peerLinks and checks preauth deadlines
        bearer.start("PreauthTest")
        settle()

        // Advance time past PREAUTH_DEADLINE (10s)
        mgr.checkPreauthDeadlines(System.currentTimeMillis() + 15_000L)

        // Assert that Noise XX authenticated link 101 survives and is NOT closed,
        // while unauthenticated link 102 IS closed!
        org.junit.Assert.assertFalse("Noise XX authenticated link must survive preauth deadline", dummy.closedLinks.contains(101L))
        assertTrue("unauthenticated link must be reaped at deadline", dummy.closedLinks.contains(102L))
    }

    @Test fun testRelayLinkMarkedSecuredAfterNoiseHandshakeSurvivesContinuousBackgroundTicks() {
        val mgr = bearer.bearerMgr
        val relay = DummyBearer("Relay")
        mgr.register(relay)

        val relayPeer = ByteArray(32) { 0x77 }

        // Establish relay link as dialer
        relay.sink?.linkUp(201L, sh.hop.HopRole.DIALER, relayPeer)
        settle()

        // Simulate Noise XX completion on relay link (global link 1_000_000):
        // Relays are never Double Ratchet peers (fake.securedAddrs is empty).
        fake.peerLinksList = listOf(uniffi.hop.PeerLink(address = relayPeer, link = 1_000_000uL))
        fake.securedAddrs = emptySet()

        // Start bearer to run tick loop
        bearer.start("RelayPreauthTest")
        settle()

        // Verify relay link was marked authenticated on the bearer
        assertTrue("relay link must be marked authenticated", relay.authenticatedLinks.contains(201L))

        // Simulate continuous background operation past multiple deadline intervals (15s, 30s, 45s)
        val now = System.currentTimeMillis()
        for (offset in listOf(15_000L, 30_000L, 45_000L)) {
            mgr.checkPreauthDeadlines(now + offset)
            org.junit.Assert.assertFalse("relay link must survive continuous operation at +${offset}ms", relay.closedLinks.contains(201L))
        }
    }
}
