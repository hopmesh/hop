package sh.hop

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * cov/kotlin: end-to-end through [HopRuntime] + a [Bearer] (parity with Smoke.runtimeSmoke / the
 * Swift RuntimeSmoke). Exercises register/start/pump/tick/stop and the inner anonymous LinkSink that
 * binds the BearerManager's global LinkId space to the node, plus transportNameOf. Skips (assumeLibhop)
 * when libhop isn't built.
 */
class HopRuntimeIntegrationTest {

    /** A trivial in-memory bearer: links up with a fixed partner; send hands bytes straight to it. */
    private class LoopbackBearer(private val dialer: Boolean) : Bearer {
        override var sink: LinkSink? = null
        override val transportName = "LOOP"
        var partner: LoopbackBearer? = null
        override fun start() = sink?.linkUp(1, if (dialer) HopRole.DIALER else HopRole.ACCEPTOR, ByteArray(0)) ?: Unit
        override fun stop() = sink?.linkDown(1) ?: Unit
        override fun send(bytes: ByteArray, link: Long) { partner?.sink?.linkBytes(1, bytes) } // out on A == in on B
    }

    @Test
    fun runtimeDeliversThroughABearerAndReportsTransport() {
        assumeLibhop()
        val bA = LoopbackBearer(dialer = true)
        val bB = LoopbackBearer(dialer = false)
        bA.partner = bB
        bB.partner = bA

        val rtA = HopRuntime(HopNode.ephemeral())
        val rtB = HopRuntime(HopNode.ephemeral())
        try {
            var now = 1_700_000_000_000L
            rtA.tick(now); rtB.tick(now)
            rtA.node.publishPrekey(); rtB.node.publishPrekey()
            val bAddr = rtB.node.address()
            rtA.register(bA); rtB.register(bB)
            rtA.start(); rtB.start()

            fun pump(rounds: Int, done: () -> Boolean = { false }): Boolean {
                repeat(rounds) {
                    rtA.pump(); rtB.pump()
                    now += 100; rtA.tick(now); rtB.tick(now)
                    if (done()) return true
                }
                return done()
            }

            pump(50) // handshake + prekey gossip
            val text = "hello through Kotlin HopRuntime + a Bearer"
            val id = rtA.node.send(bAddr, body = text.toByteArray(), requestAck = true)
            assertNotNull(id)

            var got: HopMessage? = null
            var accepted = false
            val ok = pump(400) {
                rtB.node.pollInbox { got = it }
                if (!accepted) got?.let { accepted = rtB.node.acceptInbox(it.id) }
                got != null && rtA.node.delivered(id!!)
            }
            assertTrue(ok, "the runtime + bearer should deliver and ack")
            assertTrue(accepted, "the host accepted the persisted message")
            assertEquals(text, String(got!!.body))

            // The BearerManager minted a process-global LinkId (base 1_000_000) and knows its transport.
            assertEquals("LOOP", rtB.bearers.transportNameOf(1_000_000))

            rtA.stop(); rtB.stop()
        } finally {
            rtA.node.close(); rtB.node.close()
        }
    }
}
