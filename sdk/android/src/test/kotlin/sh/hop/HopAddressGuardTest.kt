package sh.hop

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/**
 * quality/kotlin: the C ABI reads EXACTLY 32 bytes from an address / bundle-id / request-id pointer,
 * regardless of the Kotlin array's length. A wrapper method that forwards a caller's ByteArray straight
 * to native would let a shorter array trigger an out-of-bounds read in native code (undefined behavior),
 * so every such method validates `size == 32` first and throws IllegalArgumentException instead of
 * handing native a mis-sized buffer - the same guard [HopAddress.base58] already applies to its address.
 *
 * These tests drive the real node so the guard runs on the actual call path (not a reflected stub). They
 * are revert-proof: with the guard removed, each call reaches native with a 5-byte buffer for a 32-byte
 * read, which does NOT throw IllegalArgumentException (it reads out of bounds and returns), so
 * `assertFailsWith<IllegalArgumentException>` fails.
 */
class HopAddressGuardTest {

    private val invalidSizes = listOf(0, 1, 31, 33)
    private val ok = ByteArray(32)

    private fun assertEveryInvalidSizeRejected(call: (ByteArray) -> Unit) {
        for (size in invalidSizes) {
            assertFailsWith<IllegalArgumentException>("accepted $size bytes") { call(ByteArray(size)) }
        }
    }

    @Test
    fun sendRejectsAMisSizedDestination() {
        assumeLibhop()
        HopNode.ephemeral().use { n ->
            assertEveryInvalidSizeRejected { n.send(it, body = ByteArray(1)) }
        }
    }

    @Test
    fun sendToRejectsAMisSizedDestination() {
        assumeLibhop()
        HopNode.ephemeral().use { n ->
            assertEveryInvalidSizeRejected { n.sendTo(it, body = ByteArray(1)) }
        }
    }

    @Test
    fun isSecuredRejectsAMisSizedAddress() {
        assumeLibhop()
        HopNode.ephemeral().use { n ->
            assertEveryInvalidSizeRejected { n.isSecured(it) }
        }
    }

    @Test
    fun statusRejectsAMisSizedBundleId() {
        assumeLibhop()
        HopNode.ephemeral().use { n ->
            assertEveryInvalidSizeRejected { n.status(it) }
        }
    }

    @Test
    fun sendServiceRequestRejectsAMisSizedDestination() {
        assumeLibhop()
        HopNode.ephemeral().use { n ->
            assertEveryInvalidSizeRejected { n.sendServiceRequest(it, "svc", "m", ByteArray(0)) }
        }
    }

    @Test
    fun sendServiceResponseRejectsAMisSizedIdentifier() {
        assumeLibhop()
        HopNode.ephemeral().use { n ->
            assertEveryInvalidSizeRejected { n.sendServiceResponse(it, ok, 200, ByteArray(0)) }
            assertEveryInvalidSizeRejected { n.sendServiceResponse(ok, it, 200, ByteArray(0)) }
        }
    }

    @Test
    fun inboxAcceptanceAndBase58RejectMisSizedBuffers() {
        assumeLibhop()
        HopNode.ephemeral().use { n ->
            assertEveryInvalidSizeRejected { n.acceptInbox(it) }
            assertEveryInvalidSizeRejected { HopAddress.base58(it) }
            assertFalse(n.acceptInbox(ok))
            assertTrue(HopAddress.base58(ok).isNotEmpty())
        }
    }

    @Test
    fun correctlySizedBuffersDoNotTripTheGuard() {
        // The guard must reject ONLY mis-sized buffers: a 32-byte address/id sails through to native
        // (returning null/false for an unconnected peer), never an IllegalArgumentException. This pins
        // that the fix is pure input validation and does not break the happy path.
        assumeLibhop()
        HopNode.ephemeral().use { n ->
            n.send(ok, body = ByteArray(1))                    // no throw (returns null: no session yet)
            n.sendTo(ok, body = ByteArray(1))                  // no throw
            n.isSecured(ok)                                    // no throw (false)
            n.status(ok)                                       // no throw (a HopStatus)
            n.sendServiceRequest(ok, "svc", "m", ByteArray(0)) // no throw
            n.sendServiceResponse(ok, ok, 200, ByteArray(0))   // no throw
        }
    }
}
