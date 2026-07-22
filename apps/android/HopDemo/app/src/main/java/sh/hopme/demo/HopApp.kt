package sh.hopme.demo

import android.app.Application
import android.util.Log
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter

/**
 * D-crash: process-wide uncaught-exception logger. Writes the failing thread + stack to
 * `filesDir/hop-crash.log` so an `adb pull` (or the app's own diagnostics) surfaces the last crash,
 * the pre-distribution stand-in for crash reporting. Chains to the platform's default handler so the
 * usual crash dialog / process kill still happens. (Structured telemetry + opt-in scrubbed export is
 * the launch-gate follow-on.)
 */
class HopApp : Application() {
    override fun onCreate() {
        super.onCreate()
        val prior = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, e ->
            runCatching {
                val sw = StringWriter()
                e.printStackTrace(PrintWriter(sw))
                File(filesDir, "hop-crash.log").writeText("UNCAUGHT on ${thread.name}:\n$sw")
                Log.e("HOPLOG", "CRASH on ${thread.name}", e)
            }
            prior?.uncaughtException(thread, e)
        }
    }
}
