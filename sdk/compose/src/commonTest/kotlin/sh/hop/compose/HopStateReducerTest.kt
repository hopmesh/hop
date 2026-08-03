package sh.hop.compose

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class HopStateReducerTest {
    private fun peer(b: Int, name: String? = null, secured: Boolean = false) =
        HopPeer(HopAddress.of(ByteArray(32) { b.toByte() }), "b58_$b", name, secured)

    private fun msg(id: String, p: HopPeer, dir: HopDirection, at: Long, delivery: HopDelivery = HopDelivery.Pending) =
        HopMessage(id, p.address, dir, "text/plain", id.encodeToByteArray(), 0, at, delivery)

    @Test
    fun started_and_stopped_toggle_running() {
        var s = reduceHopState(HopClientState(), HopEvent.Started(peer(1)))
        assertTrue(s.running)
        assertEquals(peer(1), s.self)
        s = reduceHopState(s, HopEvent.Stopped("boom"))
        assertTrue(!s.running)
        assertEquals("boom", s.lastError)
    }

    @Test
    fun messages_group_by_peer_and_order_oldest_first() {
        val a = peer(2)
        var s = HopClientState()
        s = reduceHopState(s, HopEvent.MessageObserved(msg("m2", a, HopDirection.Inbound, 200), a))
        s = reduceHopState(s, HopEvent.MessageObserved(msg("m1", a, HopDirection.Outbound, 100), a))
        val convo = s.conversation(a.address)!!
        assertEquals(listOf("m1", "m2"), convo.messages.map { it.id })
        assertEquals("m2", convo.lastMessage!!.id)
    }

    @Test
    fun conversations_sort_by_recent_activity() {
        val a = peer(2)
        val b = peer(3)
        var s = HopClientState()
        s = reduceHopState(s, HopEvent.MessageObserved(msg("a1", a, HopDirection.Inbound, 100), a))
        s = reduceHopState(s, HopEvent.MessageObserved(msg("b1", b, HopDirection.Inbound, 500), b))
        assertEquals(b.address, s.conversations.first().peer.address)
        // A newer message in conversation A moves it to the front.
        s = reduceHopState(s, HopEvent.MessageObserved(msg("a2", a, HopDirection.Inbound, 900), a))
        assertEquals(a.address, s.conversations.first().peer.address)
    }

    @Test
    fun repeated_message_id_updates_in_place_not_duplicated() {
        val a = peer(2)
        var s = HopClientState()
        s = reduceHopState(s, HopEvent.MessageObserved(msg("dup", a, HopDirection.Inbound, 100), a))
        s = reduceHopState(s, HopEvent.MessageObserved(msg("dup", a, HopDirection.Inbound, 100, HopDelivery.Delivered), a))
        val convo = s.conversation(a.address)!!
        assertEquals(1, convo.messages.size)
        assertEquals(HopDelivery.Delivered, convo.messages.single().delivery)
    }

    @Test
    fun delivery_changed_advances_matching_message_only() {
        val a = peer(2)
        var s = reduceHopState(HopClientState(), HopEvent.MessageObserved(msg("out", a, HopDirection.Outbound, 100), a))
        s = reduceHopState(s, HopEvent.DeliveryChanged("out", HopDelivery.Relayed))
        assertEquals(HopDelivery.Relayed, s.conversation(a.address)!!.messages.single().delivery)
        // An unknown id is a no-op: no phantom conversation appears.
        val before = s
        s = reduceHopState(s, HopEvent.DeliveryChanged("ghost", HopDelivery.Delivered))
        assertEquals(before, s)
    }

    @Test
    fun peer_update_merges_presence_without_touching_messages() {
        val bare = peer(4)
        var s = reduceHopState(HopClientState(), HopEvent.MessageObserved(msg("m", bare, HopDirection.Inbound, 100), bare))
        s = reduceHopState(s, HopEvent.PeerUpdated(peer(4, name = "Grace", secured = true)))
        val convo = s.conversation(bare.address)!!
        assertEquals("Grace", convo.peer.name)
        assertTrue(convo.peer.secured)
        assertEquals(1, convo.messages.size)
    }

    @Test
    fun message_only_update_preserves_earlier_presence_facts() {
        val named = peer(5, name = "Ada", secured = true)
        var s = reduceHopState(HopClientState(), HopEvent.MessageObserved(msg("m1", named, HopDirection.Inbound, 100), named))
        // A later message carrying only a bare peer record must not wipe the known name/secured flag.
        val bare = peer(5)
        s = reduceHopState(s, HopEvent.MessageObserved(msg("m2", bare, HopDirection.Inbound, 200), bare))
        val convo = s.conversation(named.address)!!
        assertEquals("Ada", convo.peer.name)
        assertTrue(convo.peer.secured)
    }

    @Test
    fun empty_state_has_no_conversation() {
        assertNull(HopClientState().conversation(peer(9).address))
        assertTrue(HopClientState().allMessages().isEmpty())
    }
}
