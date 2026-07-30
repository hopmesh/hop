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

    // Per-transport enablement (integrators do not all want every radio) ------------------------

    @Test fun everything_is_enabled_by_default_so_registering_is_unchanged() {
        val mgr = BearerManager()
        val ble = FakeBearer("BT"); val relay = FakeBearer("Relay")
        mgr.register(ble); mgr.register(relay)
        assertTrue(mgr.isEnabled("BT"))
        assertTrue(mgr.isEnabled("Relay"))
        assertEquals(mapOf("BT" to true, "Relay" to true), mgr.bearerStates())
        mgr.start()
        assertEquals(1, ble.started)
        assertEquals(1, relay.started, "a fresh manager starts every bearer, as before")
    }

    @Test fun disabling_stops_only_that_transport() {
        val mgr = BearerManager()
        val ble = FakeBearer("BT"); val relay = FakeBearer("Relay")
        mgr.register(ble); mgr.register(relay)
        mgr.start()
        assertTrue(mgr.setEnabled("Relay", false))
        assertEquals(1, relay.stopped)
        assertEquals(0, ble.stopped, "disabling one transport must not disturb another")
        assertTrue(!mgr.isEnabled("Relay"))
        assertTrue(mgr.isEnabled("BT"))
    }

    /**
     * The property that makes this safe. Stopping a bearer without downing its links would leave the
     * node holding a path that can never carry bytes again, so it would keep choosing that dead path
     * instead of re-offering the bundle over another transport.
     */
    @Test fun disabling_tears_down_that_bearers_live_links_and_leaves_others_alone() {
        val sink = CapturingSink()
        val mgr = BearerManager(baseLinkId = 500)
        mgr.sink = sink
        val ble = FakeBearer("BT"); val relay = FakeBearer("Relay")
        mgr.register(ble); mgr.register(relay)
        mgr.start()

        ble.sink?.linkUp(1, HopRole.DIALER, byteArrayOf(0xAA.toByte()))     // global 500
        relay.sink?.linkUp(7, HopRole.DIALER, byteArrayOf(0xBB.toByte()))   // global 501
        relay.sink?.linkUp(8, HopRole.ACCEPTOR, byteArrayOf(0xCC.toByte())) // global 502
        assertContentEquals(listOf(500L, 501L, 502L), sink.ups.map { it.link })

        mgr.setEnabled("Relay", false)
        assertContentEquals(listOf(501L, 502L), sink.downs, "every link the relay owned is downed, in id order")

        // Routing for the surviving transport is untouched...
        mgr.send(byteArrayOf(1), 500L)
        assertEquals(1, ble.sent.size)
        // ...and the torn-down globals no longer route, so a late send cannot reach a dead pipe.
        mgr.send(byteArrayOf(2), 501L)
        assertEquals(0, relay.sent.size, "a global id whose bearer was disabled must not route")
        assertNull(mgr.transportNameOf(501L))
    }

    @Test fun a_disabled_bearer_stays_down_across_a_stop_start_cycle() {
        val mgr = BearerManager()
        val ble = FakeBearer("BT"); val relay = FakeBearer("Relay")
        mgr.register(ble); mgr.register(relay)
        mgr.start()
        mgr.setEnabled("Relay", false)
        val before = relay.started

        mgr.stop(); mgr.start()   // the host restarting the mesh must not revive a disabled transport
        assertEquals(before, relay.started, "a disabled transport must not come back on start()")
        assertEquals(2, ble.started, "the enabled one restarts normally")
        assertTrue(!mgr.isEnabled("Relay"))
    }

    @Test fun re_enabling_starts_it_again_and_only_when_the_manager_is_started() {
        val mgr = BearerManager()
        val relay = FakeBearer("Relay")
        mgr.register(relay)

        // Toggled BEFORE start: no start call, the setting just waits for start().
        mgr.setEnabled("Relay", false)
        mgr.setEnabled("Relay", true)
        assertEquals(0, relay.started, "enablement before start() must not start the bearer early")
        mgr.start()
        assertEquals(1, relay.started)

        // Toggled AFTER start: takes effect immediately.
        mgr.setEnabled("Relay", false)
        mgr.setEnabled("Relay", true)
        assertEquals(2, relay.started)
    }

    @Test fun is_idempotent_and_reports_an_unknown_transport() {
        val mgr = BearerManager()
        val relay = FakeBearer("Relay")
        mgr.register(relay)
        mgr.start()
        mgr.setEnabled("Relay", false); mgr.setEnabled("Relay", false)
        assertEquals(1, relay.stopped, "disabling twice must stop once")
        mgr.setEnabled("Relay", true); mgr.setEnabled("Relay", true)
        assertEquals(2, relay.started, "enabling twice must start once")
        assertTrue(!mgr.setEnabled("Nope", false), "an unknown transport reports no match")
        assertTrue(!mgr.isEnabled("Nope"))
    }

    @Test fun two_bearers_sharing_a_name_toggle_as_one_group() {
        // transportName is the handle, so a shared name is deliberately one addressable group rather
        // than an arbitrary pick between them.
        val mgr = BearerManager()
        val a = FakeBearer("Relay"); val b = FakeBearer("Relay")
        mgr.register(a); mgr.register(b)
        mgr.start()
        mgr.setEnabled("Relay", false)
        assertEquals(1, a.stopped); assertEquals(1, b.stopped)
        assertEquals(mapOf("Relay" to false), mgr.bearerStates())
    }

    // PLAT-001: a bearer that is disabled or stopped cannot surface a link ----------------------
    //
    // The regression the audit named: enablement was enforced only where the manager called INTO a
    // bearer (start/stop), never where a bearer called BACK. A BLE link that was open but had not yet
    // completed HELLO when the user switched the transport off finished its handshake afterwards,
    // called sink.linkUp, and the manager minted it a global id, so the "disabled" transport was
    // routing node packets again while the UI still said disabled. Each of these fails without the
    // guard in up().

    @Test fun a_link_surfaced_after_disabling_is_refused() {
        val sink = CapturingSink()
        val mgr = BearerManager(baseLinkId = 700)
        mgr.sink = sink
        val ble = FakeBearer("BT")
        mgr.register(ble)
        mgr.start()

        mgr.setEnabled("BT", false)
        // The bearer's stop() has returned, but a channel that was mid-handshake completes now.
        ble.sink!!.linkUp(1, HopRole.ACCEPTOR, byteArrayOf(0xAA.toByte()))

        assertEquals(0, sink.ups.size, "a disabled bearer must not surface a link to the consumer")
        assertEquals(emptyMap(), mgr.activeTransports(), "activeTransports must agree with bearerStates")
        assertEquals(mapOf("BT" to false), mgr.bearerStates())
        assertNull(mgr.transportNameOf(700L), "no global id may have been minted for it")
        // And nothing routes over it.
        mgr.send(byteArrayOf(1), 700L)
        assertEquals(0, ble.sent.size, "a disabled bearer must never take a packet from send()")
        // Its bytes/down callbacks are inert too (nothing was ever mapped).
        ble.sink!!.linkBytes(1, byteArrayOf(2))
        ble.sink!!.linkDown(1)
        assertEquals(0, sink.bytes.size)
        assertEquals(0, sink.downs.size)
    }

    @Test fun a_link_surfaced_after_the_manager_stopped_is_refused_until_restart() {
        val sink = CapturingSink()
        val mgr = BearerManager(baseLinkId = 800)
        mgr.sink = sink
        val ble = FakeBearer("BT")
        mgr.register(ble)
        mgr.start()
        mgr.stop()

        ble.sink!!.linkUp(1, HopRole.DIALER, byteArrayOf(0xBB.toByte()))
        assertEquals(0, sink.ups.size, "a stopped bearer must not surface a link")
        assertEquals(emptyMap(), mgr.activeTransports())

        // Restarting the mesh re-arms it: the bearer is meant to be running again.
        mgr.start()
        ble.sink!!.linkUp(2, HopRole.DIALER, byteArrayOf(0xBB.toByte()))
        assertContentEquals(listOf(800L), sink.ups.map { it.link }, "a restarted bearer surfaces links again")
        assertEquals(mapOf("BT" to 1), mgr.activeTransports())
    }

    @Test fun re_enabling_restores_the_ability_to_surface_links() {
        val sink = CapturingSink()
        val mgr = BearerManager(baseLinkId = 950)
        mgr.sink = sink
        val relay = FakeBearer("Relay")
        mgr.register(relay)
        mgr.start()
        mgr.setEnabled("Relay", false)
        relay.sink!!.linkUp(1, HopRole.DIALER, byteArrayOf(0xCC.toByte()))
        assertEquals(0, sink.ups.size)

        mgr.setEnabled("Relay", true)
        relay.sink!!.linkUp(2, HopRole.DIALER, byteArrayOf(0xCC.toByte()))
        assertContentEquals(listOf(950L), sink.ups.map { it.link }, "re-enabling must not leave the transport muted")
        mgr.send(byteArrayOf(9), 950L)
        assertEquals(1, relay.sent.size)
    }

    @Test fun disabling_one_transport_does_not_mute_another() {
        val sink = CapturingSink()
        val mgr = BearerManager(baseLinkId = 1_100)
        mgr.sink = sink
        val ble = FakeBearer("BT"); val relay = FakeBearer("Relay")
        mgr.register(ble); mgr.register(relay)
        mgr.start()
        mgr.setEnabled("Relay", false)

        relay.sink!!.linkUp(1, HopRole.DIALER, byteArrayOf(1))   // refused
        ble.sink!!.linkUp(1, HopRole.DIALER, byteArrayOf(2))     // still fine
        assertContentEquals(listOf(1_100L), sink.ups.map { it.link })
        assertEquals(mapOf("BT" to 1), mgr.activeTransports())
    }

    /** A disabled bearer that throws on stop must not prevent its links being torn down (F-10). */
    @Test fun a_bearer_throwing_on_stop_still_gets_its_links_torn_down() {
        val sink = CapturingSink()
        val mgr = BearerManager(baseLinkId = 900)
        mgr.sink = sink
        val boom = ThrowingBearer()
        mgr.register(boom)
        boom.sink?.linkUp(1, HopRole.DIALER, byteArrayOf(1))   // global 900
        mgr.setEnabled("Boom", false)
        assertContentEquals(listOf(900L), sink.downs, "the throw is swallowed; the link still goes down")
    }

    // PLAT-001 (closure): enablement is keyed by transportName, not by bearer object -----------------
    //
    // The invariant is stated PER NAME: "no bearer carrying that transportName may surface a new
    // linkUp". Keyed by object identity, a bearer registered after the toggle carried no entry, so it
    // started, its links were accepted, and bearerStates() ORed the tag back to true. This fails
    // against an identity-keyed `disabled`.
    @Test fun a_bearer_registered_under_an_already_disabled_name_is_dormant() {
        val sink = CapturingSink()
        val mgr = BearerManager(baseLinkId = 1_300)
        mgr.sink = sink
        val first = FakeBearer("Relay")
        mgr.register(first)
        mgr.start()
        mgr.setEnabled("Relay", false)

        // A second relay bearer joins the (disabled) group afterwards: a config reload, or a second
        // relay endpoint added while the transport is switched off.
        val second = FakeBearer("Relay")
        mgr.register(second)

        assertEquals(0, second.started, "registering into a disabled tag must not start the bearer")
        assertTrue(!mgr.isEnabled("Relay"))
        assertEquals(mapOf("Relay" to false), mgr.bearerStates(), "one bearer cannot flip the group on")

        second.sink!!.linkUp(1, HopRole.DIALER, byteArrayOf(0xD))
        assertEquals(0, sink.ups.size, "a bearer under a disabled name must not surface a link either")
        assertEquals(emptyMap(), mgr.activeTransports())
        assertNull(mgr.transportNameOf(1_300))

        // A restart must not resurrect it: the setting outlives the mesh lifecycle.
        mgr.stop(); mgr.start()
        assertEquals(0, second.started)
        second.sink!!.linkUp(2, HopRole.DIALER, byteArrayOf(0xD))
        assertEquals(0, sink.ups.size)

        // Enabling the tag brings the whole group up, including the late arrival.
        mgr.setEnabled("Relay", true)
        assertEquals(1, second.started)
        second.sink!!.linkUp(3, HopRole.DIALER, byteArrayOf(0xD))
        assertContentEquals(listOf(1_300L), sink.ups.map { it.link })
        assertEquals(mapOf("Relay" to 1), mgr.activeTransports())
    }
}
