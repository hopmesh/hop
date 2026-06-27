package net.waldrip.blelab

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED) {
            BleService.start(context)
            AnchorWatchdogReceiver.schedule(context) // alarms are cleared on reboot — re-arm
        }
    }
}
