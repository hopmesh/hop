package sh.hop

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

/**
 * quality-cov: the C-ABI wrapper's owned value types (HopMessage / HopServiceRequest /
 * HopServiceResponse) carry mutable ByteArray fields, so they hand-roll content-based equals/hashCode
 * and expose *Copy() accessors (a data class can't defensively copy from its generated getters). These
 * pin two contracts that a forensic/aliasing bug would break: (1) the *Copy() accessors return an
 * INDEPENDENT array (mutating it can't corrupt the value), and (2) equals/hashCode are value-based over
 * the bytes. Pure JVM: constructing these values never touches libhop.
 */
class HopValueTypesTest {

    private fun bytes(vararg b: Int) = ByteArray(b.size) { b[it].toByte() }

    // ---- HopMessage --------------------------------------------------------------------

    @Test
    fun messageCopiesAreIndependentOfTheValue() {
        val from = bytes(1, 2, 3)
        val body = bytes(9, 8, 7)
        val m = HopMessage(from = from, contentType = "text/plain", body = body, hops = 2u, createdAt = 100L)

        val fc = m.fromCopy()
        val bc = m.bodyCopy()
        assertContentEquals(from, fc)
        assertContentEquals(body, bc)
        // Scribble on the copies: the message's own arrays must be untouched.
        fc[0] = 0x7f
        bc[0] = 0x7f
        assertEquals(1.toByte(), m.from[0], "fromCopy must not alias the message's from array")
        assertEquals(9.toByte(), m.body[0], "bodyCopy must not alias the message's body array")
    }

    @Test
    fun messageEqualsIsContentBasedNotReference() {
        val a = HopMessage(bytes(1, 2), "text/plain", bytes(3, 4), 1u, 50L)
        val b = HopMessage(bytes(1, 2), "text/plain", bytes(3, 4), 1u, 50L)   // distinct arrays, same bytes
        assertEquals(a, b)
        assertEquals(a.hashCode(), b.hashCode())
    }

    @Test
    fun messageInequalityOnEveryField() {
        val base = HopMessage(bytes(1), "text/plain", bytes(2), 1u, 10L)
        assertNotEquals(base, base.copy(from = bytes(9)))
        assertNotEquals(base, base.copy(contentType = "image/png"))
        assertNotEquals(base, base.copy(body = bytes(9)))
        assertNotEquals(base, base.copy(hops = 2u))
        assertNotEquals(base, base.copy(createdAt = 11L))
    }

    @Test
    fun messageNotEqualToOtherTypesOrNull() {
        val m = HopMessage(bytes(1), "text/plain", bytes(2), 1u, 10L)
        assertFalse(m.equals(null))
        assertFalse(m.equals("not a message"))
        assertTrue(m.equals(m))   // reference-equal fast path
    }

    // ---- HopServiceRequest -------------------------------------------------------------

    @Test
    fun serviceRequestCopiesAreIndependent() {
        val from = bytes(1, 1)
        val reqId = bytes(2, 2)
        val args = bytes(3, 3)
        val r = HopServiceRequest(from, reqId, "svc", "method", args)

        val fc = r.fromCopy(); val rc = r.requestIdCopy(); val ac = r.argsCopy()
        fc[0] = 0x7f; rc[0] = 0x7f; ac[0] = 0x7f
        assertEquals(1.toByte(), r.from[0])
        assertEquals(2.toByte(), r.requestId[0])
        assertEquals(3.toByte(), r.args[0])
    }

    @Test
    fun serviceRequestEqualsAndHashAreContentBased() {
        val a = HopServiceRequest(bytes(1), bytes(2), "svc", "m", bytes(3))
        val b = HopServiceRequest(bytes(1), bytes(2), "svc", "m", bytes(3))
        assertEquals(a, b)
        assertEquals(a.hashCode(), b.hashCode())
        assertNotEquals(a, a.copy(service = "other"))
        assertNotEquals(a, a.copy(method = "other"))
        assertNotEquals(a, a.copy(requestId = bytes(9)))
        assertFalse(a.equals(null))
        assertFalse(a.equals(42))
    }

    // ---- HopServiceResponse ------------------------------------------------------------

    @Test
    fun serviceResponseCopiesAreIndependent() {
        val from = bytes(4, 4)
        val forId = bytes(5, 5)
        val body = bytes(6, 6)
        val r = HopServiceResponse(from, forId, status = 200, body = body)

        val fc = r.fromCopy(); val ic = r.forRequestIdCopy(); val bc = r.bodyCopy()
        fc[0] = 0x7f; ic[0] = 0x7f; bc[0] = 0x7f
        assertEquals(4.toByte(), r.from[0])
        assertEquals(5.toByte(), r.forRequestId[0])
        assertEquals(6.toByte(), r.body[0])
    }

    @Test
    fun serviceResponseEqualsAndHashAreContentBased() {
        val a = HopServiceResponse(bytes(1), bytes(2), 200, bytes(3))
        val b = HopServiceResponse(bytes(1), bytes(2), 200, bytes(3))
        assertEquals(a, b)
        assertEquals(a.hashCode(), b.hashCode())
        assertNotEquals(a, a.copy(status = 404))
        assertNotEquals(a, a.copy(body = bytes(9)))
        assertNotEquals(a, a.copy(forRequestId = bytes(9)))
        assertFalse(a.equals(null))
        assertFalse(a.equals("x"))
    }

    // ---- HopStatus / HopRole (immutable primitives) ------------------------------------

    @Test
    fun hopStatusIsValueEqual() {
        val a = HopStatus(relayed = 3, delivered = true, forwardHops = 2u, forwardMs = 1500)
        val b = HopStatus(relayed = 3, delivered = true, forwardHops = 2u, forwardMs = 1500)
        assertEquals(a, b)
        assertEquals(a.hashCode(), b.hashCode())
        assertNotEquals(a, a.copy(delivered = false))
    }

    @Test
    fun hopRoleCarriesTheNoiseWireCode() {
        // DIALER=0 / ACCEPTOR=1 is the exact int the C ABI expects for hop_link_up(role).
        assertEquals(0, HopRole.DIALER.c)
        assertEquals(1, HopRole.ACCEPTOR.c)
    }

    @Test
    fun uint8HopCountsSurfaceUnsignedNotNegative() {
        // pass-18 F-1/F-2, the ACTUAL bug the UByte fields exist to prevent, exercised at the boundary
        // that a real mesh test never reaches. The C ABI hop-count fields are uint8_t; JNA marshals a
        // uint8_t of 200 as the signed Byte -56. The wrapper reinterprets `.toUByte()`, so the public
        // field must read 200u, NOT a negative number. This is the reinterpretation both HopMessage.hops
        // (F-9) and HopStatus.forwardHops (F-1) rely on; assert it directly rather than via a `>= 0`
        // check that is vacuously true for any UByte.
        assertEquals(200u.toUByte(), (-56).toByte().toUByte(), "uint8_t 200 marshals via Byte -56")
        assertEquals(255u.toUByte(), (-1).toByte().toUByte(), "uint8_t 255 marshals via Byte -1")

        val msg = HopMessage(bytes(1), "text/plain", bytes(2), hops = (-56).toByte().toUByte(), createdAt = 0L)
        assertEquals(200u.toUByte(), msg.hops)
        assertTrue(msg.hops > 127u, "a high hop count reads as > 127, not negative")

        val st = HopStatus(relayed = 0, delivered = true, forwardHops = (-1).toByte().toUByte(), forwardMs = 0)
        assertEquals(255u.toUByte(), st.forwardHops)
        assertTrue(st.forwardHops > 127u, "a high forward-hop count reads as > 127, not negative")
    }
}
