package sh.hop

import java.io.File
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * cov/kotlin: drives the REAL libhop through [HopNode] over an in-memory loopback, covering the
 * JNA/native surface (HopNode + its Companion + lifecycle owner + HopAddress base58) that the radio-free
 * unit tests deliberately can't reach. Each native-touching test skips (assumeLibhop) when the lib
 * isn't built, so the pure-Kotlin suite still runs standalone.
 */
class HopNodeIntegrationTest {

    @Test
    fun ephemeralExposesA32ByteAddress() {
        assumeLibhop()
        HopNode.ephemeral().use { n ->
            assertEquals(32, n.address().size)
        }
    }

    @Test
    fun withSecretRestoresTheSameIdentity() {
        assumeLibhop()
        HopNode.ephemeral().use { a ->
            val secret = a.secret()
            assertEquals(32, secret.size)
            HopNode.withSecret(secret).use { b ->
                assertTrue(
                    a.address().contentEquals(b.address()),
                    "the same identity secret must restore the same address",
                )
            }
        }
    }

    @Test
    fun openIsPersistentForARealPathAndFallsBackForABadOne() {
        assumeLibhop()
        val dir = Files.createTempDirectory("hop-kt-open").toFile()
        try {
            val node = HopNode.open(File(dir, "node.db").absolutePath)
            assertNotNull(node)
            node!!.use {
                assertTrue(it.isPersistent(), "a real path opens with durable storage")
                assertEquals(0, it.rehydrateDropped(), "a fresh db drops nothing on rehydrate")
            }
            // F-26: a path under a non-existent directory can't be opened. A valid-UTF-8 path never
            // returns null, so the node still comes back but runs EPHEMERALLY (isPersistent == false).
            val fallback = HopNode.open("/no/such/hop-kt-dir/node.db")
            assertNotNull(fallback)
            fallback!!.use { assertFalse(it.isPersistent(), "an unusable path falls back to ephemeral") }
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun openKeyedYieldsAPersistentNode() {
        assumeLibhop()
        val dir = Files.createTempDirectory("hop-kt-keyed").toFile()
        try {
            val key = ByteArray(32) { (it * 7).toByte() }
            val node = HopNode.openKeyed(File(dir, "node.db").absolutePath, key)
            assertNotNull(node)
            node!!.use { assertTrue(it.isPersistent()) }
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun sendDeliversAcksAndReportsFullStatus() {
        assumeLibhop()
        HopNode.ephemeral().use { a ->
            HopNode.ephemeral().use { b ->
                val loop = DirectLoopback(a, b)
                loop.handshake()
                val bAddr = b.address()

                val text = "hello over the C ABI from a Kotlin integration test"
                val id = a.send(bAddr, body = text.toByteArray(), requestAck = true)
                assertNotNull(id)
                assertEquals(32, id!!.size)

                var rejected: HopMessage? = null
                val sawRejected = loop.pump(400) {
                    b.pollInboxAccepting {
                        rejected = it
                        false
                    }
                    rejected != null
                }
                assertTrue(sawRejected, "the host should see the durable inbox item")
                assertFalse(a.delivered(id), "a rejected host write must not emit the ACK")

                var got: HopMessage? = null
                var accepted = false
                val ok = loop.pump(400) {
                    b.pollInbox { got = it }
                    if (!accepted) got?.let { accepted = b.acceptInbox(it.id) }
                    got != null && a.delivered(id)
                }
                assertTrue(ok, "the message should deliver and ack over loopback")
                assertTrue(accepted, "host acceptance should succeed after persistence")

                val msg = got!!
                assertTrue(msg.id.contentEquals(rejected!!.id), "redelivery keeps the stable inbox id")
                assertEquals(text, String(msg.body))
                assertTrue(msg.hops >= 0u)
                assertEquals(msg.body.toList(), msg.bodyCopy().toList()) // defensive-copy accessors
                assertEquals(32, msg.fromCopy().size)

                // status() reads ALL FOUR out-params (relayed / delivered / forwardHops / forwardMs).
                val st = a.status(id)
                assertTrue(st.delivered)
                assertTrue(st.relayed >= 1, "at least one peer was handed a copy")
                assertTrue(st.forwardHops >= 0u)
                assertTrue(st.forwardMs >= 0)
                assertFailsWith<IllegalArgumentException> { b.acceptInbox(ByteArray(31)) }
                assertFailsWith<IllegalArgumentException> { b.acceptInbox(ByteArray(33)) }

                // a forward-secret ratchet session now exists to B (the lock indicator).
                assertTrue(a.isSecured(bAddr))

                // sendTo: a directed send to the now directly-connected peer.
                val tracedId = a.sendTo(bAddr, body = "traced".toByteArray())
                assertNotNull(tracedId)
                assertEquals(32, tracedId!!.size)
            }
        }
    }

    @Test
    fun singleNodeIdentityAndPubSubSurface() {
        assumeLibhop()
        HopNode.ephemeral().use { n ->
            n.setName("kotlin-integration")
            n.subscribe("hps://weather/kar")
            assertTrue(n.publishPrekey())
            assertEquals(0, n.rehydrateDropped())
            assertFalse(n.isPersistent(), "an ephemeral node has no durable storage")
            assertEquals(32, n.secret().size)
            assertFalse(n.isSecured(ByteArray(32) { 9 }), "no session to an unknown address")
        }
    }

    @Test
    fun serviceRequestResponseRoundTrips() {
        assumeLibhop()
        HopNode.ephemeral().use { a ->
            HopNode.ephemeral().use { b ->
                val loop = DirectLoopback(a, b)
                loop.handshake()
                val aAddr = a.address()
                val bAddr = b.address()

                val reqId = a.sendServiceRequest(bAddr, "weather", "get", "kar".toByteArray())
                assertNotNull(reqId)

                var req: HopServiceRequest? = null
                val gotReq = loop.pump(400) { b.pollServiceRequests { req = it }; req != null }
                assertTrue(gotReq, "B should receive the service request")
                val r = req!!
                assertTrue(r.from.contentEquals(aAddr))
                assertEquals("weather", r.service)
                assertEquals("get", r.method)
                assertEquals("kar", String(r.args))
                assertEquals(32, r.requestIdCopy().size)
                assertEquals(32, r.fromCopy().size)
                assertEquals("kar", String(r.argsCopy()))

                assertTrue(b.sendServiceResponse(r.from, r.requestId, 200, "sunny".toByteArray()))

                var resp: HopServiceResponse? = null
                val gotResp = loop.pump(400) { a.pollServiceResponses { resp = it }; resp != null }
                assertTrue(gotResp, "A should receive the service response")
                val rr = resp!!
                assertTrue(rr.from.contentEquals(bAddr))
                assertTrue(rr.forRequestId.contentEquals(reqId!!))
                assertEquals(200, rr.status)
                assertEquals("sunny", String(rr.body))
                assertEquals(32, rr.fromCopy().size)
                assertEquals(32, rr.forRequestIdCopy().size)
                assertEquals("sunny", String(rr.bodyCopy()))
                var redelivered: HopServiceResponse? = null
                a.pollServiceResponses { redelivered = it }
                assertNotNull(redelivered, "a non-accepting callback must leave the response queued")
                assertTrue(a.acceptServiceResponse(rr.forRequestId))
                var afterAcceptance: HopServiceResponse? = null
                a.pollServiceResponses { afterAcceptance = it }
                assertNull(afterAcceptance, "explicit acceptance must stop redelivery")
            }
        }
    }

    // ---- F-27 safety: idempotent close + handle guard ----

    @Test
    fun doubleCloseIsANoOp() {
        assumeLibhop()
        val n = HopNode.ephemeral()
        n.close()
        n.close() // idempotent: must not double-free the native handle or throw
    }

    @Test
    fun useAfterCloseThrows() {
        assumeLibhop()
        val n = HopNode.ephemeral()
        n.close()
        val ex = assertFailsWith<IllegalStateException> { n.address() }
        assertEquals("HopNode used after close()", ex.message)
    }

    @Test
    fun deprecatedFreeDelegatesToClose() {
        assumeLibhop()
        val n = HopNode.ephemeral()
        @Suppress("DEPRECATION")
        n.free()
        // free() delegated to close(); the handle is now null, so any further use trips the guard.
        assertFailsWith<IllegalStateException> { n.publishPrekey() }
    }

    // ---- HopAddress base58 (the native encode/decode path) ----

    @Test
    fun base58RoundTripsAndRejectsGarbage() {
        assumeLibhop()
        HopNode.ephemeral().use { n ->
            val addr = n.address()
            val b58 = HopAddress.base58(addr)
            assertTrue(b58.isNotEmpty())
            assertTrue(HopAddress.fromBase58(b58)?.contentEquals(addr) == true, "base58 must round-trip")
            assertNull(HopAddress.fromBase58("garbage"), "a non-address string decodes to null")
            assertNull(HopAddress.fromBase58("not valid base58 !!!"), "invalid base58 chars decode to null")
        }
    }
}
