package sh.hop

import com.sun.jna.Pointer
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class HopNodeLifecycleTest {
    @Test
    fun closeCannotFreeUntilAnInFlightNativeCallReturns() {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val freed = CountDownLatch(1)
        val events = CopyOnWriteArrayList<String>()
        val lifecycle = NativeHandleLifecycle(Pointer.createConstant(1)) {
            events += "free"
            freed.countDown()
        }

        val caller = thread(name = "native-caller") {
            lifecycle.call {
                entered.countDown()
                assertTrue(release.await(2, TimeUnit.SECONDS))
                events += "native-return"
            }
        }
        assertTrue(entered.await(2, TimeUnit.SECONDS))
        val closer = thread(name = "node-closer") { lifecycle.close() }

        assertFalse(freed.await(100, TimeUnit.MILLISECONDS), "free raced the active native call")
        release.countDown()
        caller.join(2_000)
        closer.join(2_000)

        assertFalse(caller.isAlive)
        assertFalse(closer.isAlive)
        assertTrue(freed.await(2, TimeUnit.SECONDS))
        assertEquals(listOf("native-return", "free"), events)
        assertFailsWith<IllegalStateException> { lifecycle.call { } }
    }

    @Test
    fun reentrantCloseFromANativeCallbackDefersFreeWithoutDeadlock() {
        val events = mutableListOf<String>()
        val lifecycle = NativeHandleLifecycle(Pointer.createConstant(2)) { events += "free" }

        lifecycle.call {
            lifecycle.close()
            assertEquals(emptyList(), events)
            assertFailsWith<IllegalStateException> { lifecycle.call { } }
            events += "native-return"
        }

        assertEquals(listOf("native-return", "free"), events)
        lifecycle.close()
        assertEquals(2, events.size, "close must be idempotent")
    }
}
