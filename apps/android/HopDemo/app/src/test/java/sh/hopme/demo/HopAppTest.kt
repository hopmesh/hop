package sh.hopme.demo

import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File

/**
 * cov/android-demo: HopApp installs a process-wide uncaught-exception handler that writes the failing
 * thread + stack to filesDir/hop-crash.log and then chains to the platform's prior handler (so the usual
 * crash dialog / kill still happens). We drive it headless under Robolectric.
 *
 * To assert the chain safely we re-run onCreate with our OWN recorder installed as the default handler,
 * so `prior` captured by the installed lambda is the recorder (not Robolectric's own failing handler).
 */
@RunWith(RobolectricTestRunner::class)
@Config(application = HopApp::class)
class HopAppTest {

    @Test fun applicationDisablesPlatformBackup() {
        val app = ApplicationProvider.getApplicationContext<HopApp>()
        assertFalse(
            "history and attachments must not enter Android backup",
            app.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_ALLOW_BACKUP != 0,
        )
    }

    /** Records the last exception it was handed instead of failing the test the way Robolectric's does. */
    private class Recorder : Thread.UncaughtExceptionHandler {
        @Volatile var last: Throwable? = null
        override fun uncaughtException(t: Thread, e: Throwable) { last = e }
    }

    @Test fun crashHandler_writesCrashLogAndChainsToPrior() {
        val app = ApplicationProvider.getApplicationContext<HopApp>()

        val recorder = Recorder()
        Thread.setDefaultUncaughtExceptionHandler(recorder)
        // Re-run onCreate: the lambda it installs now captures `recorder` as its prior, and becomes the
        // active default handler. (super.onCreate is idempotent under Robolectric.)
        app.onCreate()

        val installed = Thread.getDefaultUncaughtExceptionHandler()
        assertNotNull("HopApp must install a default uncaught-exception handler", installed)
        assertTrue("installed handler must not be our recorder", installed !== recorder)

        val thread = Thread.currentThread()
        val boom = RuntimeException("kaboom-42")
        installed!!.uncaughtException(thread, boom)

        val log = File(app.filesDir, "hop-crash.log").readText()
        assertTrue("log names the failing thread", log.startsWith("UNCAUGHT on ${thread.name}:"))
        assertTrue("log contains the stack trace message", log.contains("kaboom-42"))
        assertSame("handler chains the same throwable to the prior handler", boom, recorder.last)
    }
}
