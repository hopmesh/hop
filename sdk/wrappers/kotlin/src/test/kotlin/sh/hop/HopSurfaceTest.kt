package sh.hop

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * core-ffi-06: a radio-free surface-parity check for the Kotlin C-ABI wrapper. It reflects over
 * [HopNode] (and its companion) WITHOUT loading libhop, so it runs in plain JVM CI without the
 * .so/.dylib, and asserts the methods that were previously missing relative to the Swift face are
 * present: the `withSecret` constructor and a full `status(...)` reading every hop_message_status
 * out-param (not just `delivered`). Drift like this used to be invisible because nothing checked
 * wrapper surface parity.
 *
 * Note: `HopNode`'s companion runs `Native.load("hop")` + an ABI check in its `init`, which needs the
 * native lib. We therefore reflect over declared members (which does not trigger class init of the
 * companion object) rather than calling anything, so the test needs no radios and no libhop.
 */
class HopSurfaceTest {

    @Test
    fun instanceExposesWithSecretParitySurface() {
        val methods = HopNode::class.java.declaredMethods.map { it.name }.toSet()
        // status(id): HopStatus, the full delivery status (relayed / delivered / hops / ms).
        assertTrue("status" in methods, "HopNode.status(id) missing (Swift has status(of:))")
        // delivered(id) kept for source compatibility, now delegating to status().
        assertTrue("delivered" in methods, "HopNode.delivered(id) missing")
        // The full hops:// + identity surface asserted present so a future removal trips the test.
        for (m in listOf("secret", "isSecured", "sendServiceRequest", "sendServiceResponse",
                         "pollServiceRequests", "pollServiceResponses", "sendTo", "subscribe")) {
            assertTrue(m in methods, "HopNode.$m missing")
        }
    }

    @Test
    fun companionExposesWithSecretConstructor() {
        // Load the nested Companion class by name so we don't touch HopNode.Companion (a static-field
        // read that would trigger HopNode.<clinit> → Native.load("hop")). `Class.forName(.., false, ..)`
        // resolves without initializing, keeping this test radio-/libhop-free.
        val companion = Class.forName("sh.hop.HopNode\$Companion", false, javaClass.classLoader)
        val ctors = companion.declaredMethods.map { it.name }.toSet()
        assertTrue("withSecret" in ctors, "HopNode.Companion.withSecret(secret) missing (Swift has with(secret:))")
        assertTrue("ephemeral" in ctors)
        assertTrue("open" in ctors)
        assertTrue("openKeyed" in ctors)
    }

    @Test
    fun hopStatusMirrorsSwiftFields() {
        // HopStatus data class field parity with Swift's HopStatus (relayed/delivered/forwardHops/forwardMs).
        val s = HopStatus(relayed = 3, delivered = true, forwardHops = 2u, forwardMs = 1500)
        assertEquals(3, s.relayed)
        assertTrue(s.delivered)
        assertEquals(2u.toUByte(), s.forwardHops)
        assertEquals(1500, s.forwardMs)
    }
}
