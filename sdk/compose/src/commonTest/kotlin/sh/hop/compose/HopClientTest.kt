package sh.hop.compose

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
class HopClientTest {
    private fun addr(b: Int) = HopAddress.of(ByteArray(32) { b.toByte() })

    @Test
    fun send_shows_optimistic_message_then_tracks_delivery() = runTest {
        val engine = FakeHopEngine()
        val client = HopClient(engine, backgroundScope, clock = { 1000L })
        val to = addr(9)

        val result = client.sendText(to, "hello")
        assertTrue(result is HopSendResult.Accepted)

        val convo = client.state.value.conversation(to)!!
        assertEquals(1, convo.messages.size)
        val optimistic = convo.messages.single()
        assertEquals("hello", optimistic.text)
        assertEquals(HopDirection.Outbound, optimistic.direction)
        assertEquals(HopDelivery.Pending, optimistic.delivery)
        assertEquals(1, engine.sent.size)

        val rawId = engine.sent.single().id
        engine.setStatus(rawId, EngineStatus(relayed = 2, delivered = false, forwardHops = 0, forwardMs = 0))
        client.runTick(1)
        assertEquals(HopDelivery.Relayed, client.state.value.conversation(to)!!.messages.single().delivery)

        engine.setStatus(rawId, EngineStatus(relayed = 2, delivered = true, forwardHops = 3, forwardMs = 40))
        client.runTick(2)
        assertEquals(HopDelivery.Delivered, client.state.value.conversation(to)!!.messages.single().delivery)
    }

    @Test
    fun sends_without_ack_are_not_tracked() = runTest {
        val engine = FakeHopEngine()
        val client = HopClient(engine, backgroundScope, clock = { 1L })
        client.send(addr(3), "hi".encodeToByteArray(), requestAck = false)
        val rawId = engine.sent.single().id
        engine.setStatus(rawId, EngineStatus(relayed = 5, delivered = true, forwardHops = 1, forwardMs = 1))
        client.runTick(1)
        // Not tracked, so it stays at its optimistic Pending; no status polling happens.
        assertEquals(HopDelivery.Pending, client.state.value.conversation(addr(3))!!.messages.single().delivery)
    }

    // Unconfined dispatcher: launches, emits, and collectors run eagerly and inline, so there is no
    // scheduler-timing race between subscribing to the replay=0 inbox and emitting into it.
    @Test
    fun poll_folds_inbound_into_state_and_inbox_flow() = runTest(UnconfinedTestDispatcher()) {
        val engine = FakeHopEngine()
        val client = HopClient(engine, backgroundScope, clock = { 5L })
        val from = addr(4)
        engine.markSecured(from)
        engine.deliver(from, "hi there".encodeToByteArray(), createdAtMs = 42, hops = 2)

        // Eager: the collector is subscribed before we tick, so the emission is delivered, not dropped.
        val firstInbox = async { client.inbox.first() }
        client.runTick(0)
        val received = firstInbox.await()

        val convo = client.state.value.conversation(from)!!
        assertEquals("hi there", convo.messages.single().text)
        assertEquals(HopDirection.Inbound, convo.messages.single().direction)
        assertEquals(2, convo.messages.single().hops)
        assertTrue(convo.peer.secured)
        assertEquals("hi there", received.text)

        // A second poll must not redeliver the accepted message.
        client.runTick(1)
        assertEquals(1, client.state.value.conversation(from)!!.messages.size)
    }

    @Test
    fun tick_advances_clock_and_publishes_prekey_on_cadence() = runTest {
        val engine = FakeHopEngine()
        var now = 111L
        val client = HopClient(engine, backgroundScope, HopClientConfig(prekeyEveryTicks = 3), clock = { now })
        client.runTick(0)
        assertEquals(111L, engine.lastTickMs)
        assertEquals(1, engine.prekeysPublished)
        now = 222L
        client.runTick(1)
        client.runTick(2)
        assertEquals(1, engine.prekeysPublished)
        client.runTick(3)
        assertEquals(2, engine.prekeysPublished)
        assertEquals(222L, engine.lastTickMs)
    }

    @Test
    fun start_sets_self_and_stop_closes_engine() = runTest(UnconfinedTestDispatcher()) {
        val engine = FakeHopEngine()
        val client = HopClient(engine, backgroundScope, HopClientConfig(tickIntervalMs = 10), clock = { 1L })
        client.start()
        // Eager: the loop head runs to the first delay, emitting Started and setting self.
        assertEquals(engine.address(), client.state.value.self!!.address)
        assertTrue(client.state.value.running)

        client.stop()
        // stop() runs teardown (engine close + Stopped) as its own task; flush any remainder.
        advanceUntilIdle()
        assertTrue(engine.closed)
        assertFalse(client.state.value.running)
    }

    @Test
    fun set_name_updates_self_and_engine() = runTest {
        val engine = FakeHopEngine()
        val client = HopClient(engine, backgroundScope, HopClientConfig(tickIntervalMs = 10_000), clock = { 1L })
        client.start()
        runCurrent()
        client.setName("Ada")
        assertEquals("Ada", client.state.value.self!!.name)
        assertEquals("Ada", engine.name)
    }
}
