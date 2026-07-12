package sh.hop

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

/**
 * quality-cov: [HopAddress.base58] length guard (#39-adjacent). The C `hop_address_to_base58` ALWAYS
 * reads exactly 32 bytes from the pointer regardless of the Kotlin array's length, so a shorter array
 * would read out of bounds in native code and a longer one would be silently truncated. The wrapper
 * validates the length in Kotlin FIRST and throws before ever calling into native, so we can pin the
 * guard without loading libhop (the require runs before HopNode.C is touched). The valid path and
 * fromBase58 genuinely need the native lib, so those are covered by the smoke harness, not here.
 */
class HopAddressTest {

    @Test
    fun addressLenIs32() {
        assertEquals(32, HopAddress.ADDRESS_LEN)
    }

    @Test
    fun base58RejectsAShortAddressBeforeTouchingNative() {
        // 31 bytes: the guard must reject it (a native call would read 1 byte OOB). This throws in pure
        // Kotlin, so it never loads the .so — proving the guard is the FIRST thing base58() does.
        val ex = assertFailsWith<IllegalArgumentException> { HopAddress.base58(ByteArray(31)) }
        assertEquals("Hop address must be 32 bytes, got 31", ex.message)
    }

    @Test
    fun base58RejectsALongAddress() {
        val ex = assertFailsWith<IllegalArgumentException> { HopAddress.base58(ByteArray(33)) }
        assertEquals("Hop address must be 32 bytes, got 33", ex.message)
    }

    @Test
    fun base58RejectsAnEmptyAddress() {
        assertFailsWith<IllegalArgumentException> { HopAddress.base58(ByteArray(0)) }
    }
}
