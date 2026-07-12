package sh.hop

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

/**
 * quality-cov: the transport-neutral helpers every Android bearer shares (Transport.kt). These are the
 * cross-transport tiebreaker ("greater nodeId dials", so two peers that mutually discover don't
 * double-connect) and the hex/nodeId primitives. Pure JVM, no radios, no libhop — but until now they
 * were only reached transitively by the LAN bearer's tests, so the SDK module itself scored 0 on them.
 */
class TransportHelpersTest {

    private fun bytes(vararg b: Int) = ByteArray(b.size) { b[it].toByte() }

    // ---- nodeIdGreater: unsigned big-endian compare ----------------------------------------

    @Test
    fun greaterComparesUnsignedBigEndian() {
        // 0x80 (128 unsigned) must out-rank 0x7f (127); a signed compare would wrongly call 0x80 negative.
        assertTrue(nodeIdGreater(bytes(0x80), bytes(0x7f)))
        assertFalse(nodeIdGreater(bytes(0x7f), bytes(0x80)))
    }

    @Test
    fun greaterUsesTheFirstDifferingByte() {
        val a = bytes(0x01, 0xff, 0x00)
        val b = bytes(0x01, 0x00, 0xff)
        assertTrue(nodeIdGreater(a, b))   // differ at index 1: 0xff > 0x00
        assertFalse(nodeIdGreater(b, a))
    }

    @Test
    fun equalPrefixFallsBackToLength() {
        // Same bytes as far as they go: the longer id is "greater" (the documented tiebreaker tail).
        val short = bytes(0x01, 0x02)
        val long = bytes(0x01, 0x02, 0x00)
        assertTrue(nodeIdGreater(long, short))
        assertFalse(nodeIdGreater(short, long))
    }

    @Test
    fun identicalIdsAreNotGreaterEitherWay() {
        val a = ByteArray(16) { it.toByte() }
        val b = ByteArray(16) { it.toByte() }
        assertFalse(nodeIdGreater(a, b))
        assertFalse(nodeIdGreater(b, a))
    }

    @Test
    fun exactlyOneSideDialsForAnyDistinctPair() {
        // The invariant the whole tiebreaker exists for: for two distinct ids, EXACTLY one is "greater",
        // so exactly one side dials and the pair never double-connects.
        val a = randomNodeId()
        var b = randomNodeId()
        while (a.contentEquals(b)) b = randomNodeId()   // astronomically unlikely, but be exact
        assertNotEquals(nodeIdGreater(a, b), nodeIdGreater(b, a))
    }

    // ---- toHex ---------------------------------------------------------------------------

    @Test
    fun hexIsLowercaseZeroPaddedTwoDigits() {
        assertEquals("00010aff", bytes(0x00, 0x01, 0x0a, 0xff).toHex())
    }

    @Test
    fun hexOfEmptyIsEmpty() {
        assertEquals("", ByteArray(0).toHex())
    }

    @Test
    fun hexRendersHighBitBytesUnsigned() {
        // A signed %02x would print negative bytes as e.g. "-1"; the helper must render 0x80..0xff.
        assertEquals("80ff", bytes(0x80, 0xff).toHex())
    }

    // ---- randomNodeId --------------------------------------------------------------------

    @Test
    fun randomNodeIdIs16BytesAndFresh() {
        val a = randomNodeId()
        val b = randomNodeId()
        assertEquals(16, a.size)
        assertEquals(16, b.size)
        assertFalse(a.contentEquals(b), "two CSPRNG nodeIds must not collide")
    }

    // ---- the shared log tag / background flag --------------------------------------------

    @Test
    fun tagIsTheGrepableTransportTag() {
        assertEquals("HOPLOG", TAG)
    }

    @Test
    fun backgroundFlagRoundTrips() {
        val prev = appInBackground
        try {
            appInBackground = true
            assertTrue(appInBackground)
            appInBackground = false
            assertFalse(appInBackground)
        } finally {
            appInBackground = prev
        }
    }
}
