package sh.hop.compose

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class HopValuesTest {
    @Test
    fun address_requires_exactly_32_bytes() {
        assertFailsWith<IllegalArgumentException> { HopAddress.of(ByteArray(31)) }
        assertFailsWith<IllegalArgumentException> { HopAddress.of(ByteArray(33)) }
        HopAddress.of(ByteArray(32)) // does not throw
    }

    @Test
    fun ofOrNull_is_lenient() {
        assertNull(HopAddress.ofOrNull(null))
        assertNull(HopAddress.ofOrNull(ByteArray(10)))
        assertTrue(HopAddress.ofOrNull(ByteArray(32)) != null)
    }

    @Test
    fun address_copies_defensively() {
        val raw = ByteArray(32) { 7 }
        val addr = HopAddress.of(raw)
        raw[0] = 99 // mutating the source must not change the address
        assertEquals(7, addr.toBytes()[0])
        addr.toBytes()[1] = 42 // mutating a copy must not change the address either
        assertEquals(7, addr.toBytes()[1])
    }

    @Test
    fun address_value_semantics() {
        val a = HopAddress.of(ByteArray(32) { it.toByte() })
        val b = HopAddress.of(ByteArray(32) { it.toByte() })
        val c = HopAddress.of(ByteArray(32) { (it + 1).toByte() })
        assertEquals(a, b)
        assertEquals(a.hashCode(), b.hashCode())
        assertNotEquals(a, c)
    }

    @Test
    fun message_equality_is_content_based() {
        val peer = HopAddress.of(ByteArray(32) { 3 })
        val m1 = HopMessage("id1", peer, HopDirection.Inbound, "text/plain", "hi".encodeToByteArray(), 2, 100)
        val m2 = HopMessage("id1", peer, HopDirection.Inbound, "text/plain", "hi".encodeToByteArray(), 2, 100)
        assertEquals(m1, m2)
        assertEquals(m1.hashCode(), m2.hashCode())
        assertEquals("hi", m1.text)
    }

    @Test
    fun delivery_ladder_is_ordered() {
        assertTrue(HopDelivery.Pending < HopDelivery.Relayed)
        assertTrue(HopDelivery.Relayed < HopDelivery.Delivered)
    }

    @Test
    fun hex_round_trips_low_and_high_bytes() {
        val bytes = byteArrayOf(0x00, 0x0f, 0x10, 0xff.toByte(), 0xab.toByte())
        assertEquals("000f10ffab", bytes.toHex())
    }

    @Test
    fun peer_display_name_prefers_name_then_base58_head() {
        val addr = HopAddress.of(ByteArray(32))
        assertEquals("Ada", HopPeer(addr, "b58longstring", name = "Ada").displayName)
        assertEquals("b58longs...", HopPeer(addr, "b58longstring").displayName)
    }
}
