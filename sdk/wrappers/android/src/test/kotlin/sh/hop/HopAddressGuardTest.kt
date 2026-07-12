package sh.hop

import kotlin.test.Test
import kotlin.test.assertFailsWith

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

    private val short = ByteArray(5) // deliberately not 32
    private val ok = ByteArray(32)   // a correctly-sized (zero) address/id

    @Test
    fun sendRejectsAMisSizedDestination() {
        assumeLibhop()
        HopNode.ephemeral().use { n ->
            assertFailsWith<IllegalArgumentException> { n.send(short, body = ByteArray(1)) }
        }
    }

    @Test
    fun sendToRejectsAMisSizedDestination() {
        assumeLibhop()
        HopNode.ephemeral().use { n ->
            assertFailsWith<IllegalArgumentException> { n.sendTo(short, body = ByteArray(1)) }
        }
    }

    @Test
    fun isSecuredRejectsAMisSizedAddress() {
        assumeLibhop()
        HopNode.ephemeral().use { n ->
            assertFailsWith<IllegalArgumentException> { n.isSecured(short) }
        }
    }

    @Test
    fun statusRejectsAMisSizedBundleId() {
        assumeLibhop()
        HopNode.ephemeral().use { n ->
            assertFailsWith<IllegalArgumentException> { n.status(short) }
        }
    }

    @Test
    fun sendServiceRequestRejectsAMisSizedDestination() {
        assumeLibhop()
        HopNode.ephemeral().use { n ->
            assertFailsWith<IllegalArgumentException> { n.sendServiceRequest(short, "svc", "m", ByteArray(0)) }
        }
    }

    @Test
    fun sendServiceResponseRejectsAMisSizedIdentifier() {
        assumeLibhop()
        HopNode.ephemeral().use { n ->
            // A bad `to` and, separately, a bad `for_request_id` are each rejected.
            assertFailsWith<IllegalArgumentException> { n.sendServiceResponse(short, ok, 200, ByteArray(0)) }
            assertFailsWith<IllegalArgumentException> { n.sendServiceResponse(ok, short, 200, ByteArray(0)) }
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
