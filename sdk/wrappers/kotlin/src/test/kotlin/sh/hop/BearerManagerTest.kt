package sh.hop

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * F-34: radio-free tests for the transport multiplexer. A fake [Bearer] lets us drive link
 * up/bytes/down and a fake [LinkSink] captures what the consumer sees, so we can assert the
 * global-id mapping, per-bearer routing, dedup on down, and start/stop isolation with no radios.
 */
class BearerManagerTest {

    /** A bearer that records what it was asked to send and exposes its lane sink to the test. */
    private class FakeBearer(override val transportName: String) : Bearer {
        override var sink: LinkSink? = null
        var started = 0
        var stopped = 0
        val sent = mutableListOf<Pair<Long, ByteArray>>()
        override fun start() { started++ }
        override fun stop() { stopped++ }
        override fun send(bytes: ByteArray, link: Long) { sent += link to bytes }
    }

    /** A bearer whose start() throws, to prove one failing bearer can't abort the others (F-10). */
    private class ThrowingBearer : Bearer {
        override var sink: LinkSink? = null
        override val transportName = "Boom"
        override fun start() = throw RuntimeException("BT off at launch")
        override fun stop() = throw RuntimeException("nope")
        override fun send(bytes: ByteArray, link: Long) {}
    }

    private class CapturingSink : LinkSink {
        data class Up(val link: Long, val role: HopRole, val peer: ByteArray)
        val ups = mutableListOf<Up>()
        val bytes = mutableListOf<Pair<Long, ByteArray>>()
        val downs = mutableListOf<Long>()
        override fun linkUp(link: Long, role: HopRole, peerId: ByteArray) { ups += Up(link, role, peerId) }
        override fun linkBytes(link: Long, b: ByteArray) { bytes += link to b }
        override fun linkDown(link: Long) { downs += link }
    }

    @Test
    fun mints_global_ids_from_the_base_and_translates_per_bearer() {
        val sink = CapturingSink()
        val mgr = BearerManager(baseLinkId = 1_000)
        mgr.sink = sink
        val ble = FakeBearer("BT")
        val lan = FakeBearer("LAN")
        mgr.register(ble)
        mgr.register(lan)

        // Each bearer brings up a link with its OWN local id 1; the manager must mint distinct globals.
        ble.sink!!.linkUp(1, HopRole.DIALER, byteArrayOf(0xB))
        lan.sink!!.linkUp(1, HopRole.ACCEPTOR, byteArrayOf(0xA))

        assertEquals(listOf(1_000L, 1_001L), sink.ups.map { it.link }, "globals mint from baseLinkId, monotonic")
        assertEquals(HopRole.DIALER, sink.ups[0].role)
        assertEquals("BT", mgr.transportNameOf(1_000))
        assertEquals("LAN", mgr.transportNameOf(1_001))
    }

    @Test
    fun routes_send_and_inbound_bytes_to_the_owning_bearer_only() {
        val sink = CapturingSink()
        val mgr = BearerManager(baseLinkId = 1)
        mgr.sink = sink
        val ble = FakeBearer("BT")
        val lan = FakeBearer("LAN")
        mgr.register(ble); mgr.register(lan)
        ble.sink!!.linkUp(7, HopRole.DIALER, byteArrayOf(1))   // global 1 → (ble, local 7)
        lan.sink!!.linkUp(9, HopRole.DIALER, byteArrayOf(2))   // global 2 → (lan, local 9)

        // Consumer sends on the GLOBAL id; it must reach the right bearer with its LOCAL id.
        mgr.send(byteArrayOf(42), 1)
        mgr.send(byteArrayOf(43), 2)
        assertEquals(listOf(7L to 42.toByte()), ble.sent.map { it.first to it.second[0] })
        assertEquals(listOf(9L to 43.toByte()), lan.sent.map { it.first to it.second[0] })

        // Inbound bytes on a bearer's local id surface to the consumer under the global id.
        ble.sink!!.linkBytes(7, byteArrayOf(99))
        assertContentEquals(byteArrayOf(99), sink.bytes.single().second)
        assertEquals(1L, sink.bytes.single().first)

        // A send to an unknown/closed link is a no-op (not a crash).
        mgr.send(byteArrayOf(0), 12345)
    }

    @Test
    fun down_surfaces_once_and_forgets_the_mapping() {
        val sink = CapturingSink()
        val mgr = BearerManager(baseLinkId = 1)
        mgr.sink = sink
        val ble = FakeBearer("BT")
        mgr.register(ble)
        ble.sink!!.linkUp(5, HopRole.DIALER, byteArrayOf(1)) // global 1
        ble.sink!!.linkDown(5)
        assertEquals(listOf(1L), sink.downs, "down surfaces the global id exactly once")
        // Mapping forgotten: a send on the dead global routes nowhere, and a duplicate down is ignored.
        mgr.send(byteArrayOf(1), 1)
        assertTrue(ble.sent.isEmpty(), "no routing after down")
        ble.sink!!.linkDown(5)
        assertEquals(listOf(1L), sink.downs, "a duplicate down is not re-surfaced")
        assertNull(mgr.transportNameOf(1))
    }

    @Test
    fun one_bearer_start_throwing_does_not_abort_the_others() {
        val mgr = BearerManager()
        val ok1 = FakeBearer("BT")
        val ok2 = FakeBearer("LAN")
        mgr.register(ok1)
        mgr.register(ThrowingBearer()) // its start()/stop() throw
        mgr.register(ok2)
        mgr.start() // must not propagate the throw
        mgr.stop()
        assertEquals(1, ok1.started); assertEquals(1, ok2.started, "healthy bearers still started")
        assertEquals(1, ok1.stopped); assertEquals(1, ok2.stopped, "healthy bearers still stopped")
    }
}
