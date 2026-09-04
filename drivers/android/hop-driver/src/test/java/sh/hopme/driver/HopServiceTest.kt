package sh.hopme.driver

import android.content.Intent
import androidx.test.core.app.ApplicationProvider
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.robolectric.Robolectric
import org.robolectric.Shadows.shadowOf

/** cov/android-driver: the foreground [HopService] (§22). onStartCommand promotes to foreground and
 *  starts the shared driver; here the singleton is pre-seeded with a fake-backed driver so the service
 *  runs without the AndroidKeyStore identity path (which is device-only). */
class HopServiceTest : DriverTestBase() {

    private fun seedSingleton(b: HopBearer) {
        val f = HopBearer::class.java.getDeclaredField("inst").apply { isAccessible = true }
        f.set(null, b)
    }

    @After fun clearSingleton() {
        runCatching {
            HopBearer::class.java.getDeclaredField("inst").apply { isAccessible = true }.set(null, null)
        }
    }

    @Test fun onStartCommandGoesForegroundAndStartsTheDriver() {
        val seeded = newBearer(FakeHopNode())
        seedSingleton(seeded)

        val service = Robolectric.buildService(HopService::class.java).create().get()
        val result = service.onStartCommand(Intent(), 0, 1)

        assertEquals(android.app.Service.START_STICKY, result)
        assertNull("service is not bindable", service.onBind(Intent()))
        settleOn(seeded)
        val fakeNode = seeded.node as FakeHopNode
        assertTrue("driver started via the service", fakeNode.publishedServices.contains(HopBearer.PRESENCE_SERVICE))
    }

    @Test fun companionStartLaunchesTheService() {
        HopService.start(ApplicationProvider.getApplicationContext())
        val app = ApplicationProvider.getApplicationContext<android.app.Application>()
        val started = shadowOf(app).nextStartedService
        assertTrue("HopService was started", started.component?.className?.contains("HopService") == true)
    }

    @Test fun serviceDestroyInvokesTeardownAndQuiescesDriver() {
        val seeded = newBearer(FakeHopNode())
        seedSingleton(seeded)

        val controller = Robolectric.buildService(HopService::class.java).create().startCommand(0, 1)
        settleOn(seeded)
        assertFalse("driver is not torn down initially", seeded.isTorndown)

        controller.destroy()
        assertTrue("driver was torn down on service destroy", seeded.isTorndown)
        assertNull("singleton instance was cleared on teardown", HopBearer.peek())
    }

    @Test fun serviceRestartAfterDestroyYieldsFreshGeneration() {
        val firstBearer = newBearer(FakeHopNode())
        seedSingleton(firstBearer)

        val controller = Robolectric.buildService(HopService::class.java).create().startCommand(0, 1)
        settleOn(firstBearer)
        controller.destroy()
        assertTrue("first driver was torn down", firstBearer.isTorndown)
        assertNull("singleton cleared", HopBearer.peek())

        val secondBearer = newBearer(FakeHopNode())
        seedSingleton(secondBearer)
        val restartController = Robolectric.buildService(HopService::class.java).create().startCommand(0, 2)
        settleOn(secondBearer)
        assertFalse("new driver is active", secondBearer.isTorndown)
        assertEquals("active singleton is second generation", secondBearer, HopBearer.peek())

        restartController.destroy()
        assertTrue("second driver torn down", secondBearer.isTorndown)
        assertNull("singleton cleared", HopBearer.peek())
    }
}
