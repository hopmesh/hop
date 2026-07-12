package sh.hopme.blelab

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.SystemClock
import android.util.Log

// Self-resurrection of the BLE anchor (the foreground service that advertises the connectable
// service + the iBeacon). When both apps are killed, a dead Android anchor emits no beacon, so a
// killed iOS peer can never be woken (BACKGROUND.md §7: Android is the anchor; iOS is reactive).
// A repeating exact alarm re-launches the FGS so the beacon comes back and resurrects the loop.
//
// Why this is allowed from the background on Android 12+ (which otherwise throws
// ForegroundServiceStartNotAllowedException): the user's battery-optimization exemption
// (REQUEST_IGNORE_BATTERY_OPTIMIZATIONS -> power allowlist) grants BOTH the exact-alarm permission
// (no SCHEDULE_EXACT_ALARM needed) AND the background-FGS-start exemption (#13), and a fire from an
// exact alarm is itself exemption #5. connectedDevice is NOT a while-in-use type, so the API-34
// while-in-use FGS-start restriction does not apply.
//
// HARD LIMIT (by design, document it): a user/Settings Force-Stop (or `adb am force-stop`) sets the
// package FLAG_STOPPED, which CANCELS all alarms and blocks all components until a MANUAL launch or
// reboot. Nothing recovers that until the user opens the app. `adb am kill` (soft) is survivable.
class AnchorWatchdogReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        schedule(context) // reschedule first, so the chain never breaks
        if (!BleService.isRunning) {
            Log.i(TAG, "WATCHDOG: anchor not running → restarting foreground service")
            runCatching { BleService.start(context) }
                .onFailure { Log.w(TAG, "WATCHDOG: startForegroundService failed: ${it.message}") }
        } else {
            Log.i(TAG, "WATCHDOG: anchor alive — no-op")
        }
    }

    companion object {
        const val INTERVAL_MS = 5 * 60 * 1000L // 5 min ("eventual"); matches the iBeacon cycle floor
        private const val REQUEST_CODE = 0xA3C0

        private fun pendingIntent(ctx: Context) = PendingIntent.getBroadcast(
            ctx, REQUEST_CODE, Intent(ctx, AnchorWatchdogReceiver::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        /// Schedule (or re-schedule) the next resurrection check. Idempotent.
        fun schedule(ctx: Context) {
            val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val at = SystemClock.elapsedRealtime() + INTERVAL_MS
            val pi = pendingIntent(ctx)
            // Power-allowlisted -> setExactAndAllowWhileIdle works without SCHEDULE_EXACT_ALARM and
            // fires within ~1 min even in deep Doze. Fall back to inexact (~10 min in Doze) otherwise.
            runCatching {
                if (am.canScheduleExactAlarms()) {
                    am.setExactAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, at, pi)
                } else {
                    am.setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, at, pi)
                }
            }.onFailure {
                am.setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, at, pi)
            }
        }
    }
}
