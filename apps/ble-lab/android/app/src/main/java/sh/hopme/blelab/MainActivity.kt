package sh.hopme.blelab

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import android.view.Gravity
import android.widget.LinearLayout
import android.widget.TextView

// Minimal UI: request the BLE runtime permissions, then launch the foreground service that runs
// the symmetric dual role. All proof traffic is in logcat under the HOPLOG tag.
class MainActivity : Activity() {

    private lateinit var status: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(48, 48, 48, 48)
        }
        val title = TextView(this).apply {
            text = "BLE Lab — dual-role proof of pipe"
            textSize = 20f
        }
        status = TextView(this).apply {
            text = "Requesting permissions…"
            textSize = 14f
            setPadding(0, 32, 0, 0)
        }
        root.addView(title)
        root.addView(status)
        setContentView(root)

        requestPermissionsIfNeeded()
    }

    private fun neededPermissions(): Array<String> {
        val perms = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            perms += Manifest.permission.BLUETOOTH_SCAN
            perms += Manifest.permission.BLUETOOTH_ADVERTISE
            perms += Manifest.permission.BLUETOOTH_CONNECT
        } else {
            perms += Manifest.permission.ACCESS_FINE_LOCATION
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            perms += Manifest.permission.POST_NOTIFICATIONS
        }
        return perms.filter {
            checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
        }.toTypedArray()
    }

    private fun requestPermissionsIfNeeded() {
        val missing = neededPermissions()
        if (missing.isEmpty()) {
            launch()
        } else {
            requestPermissions(missing, REQ)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQ) return
        // Proceed regardless: BLE perms drive the work; if denied, the service logs the failure.
        if (neededPermissions().isEmpty()) {
            launch()
        } else {
            status.text = "Some permissions denied — BLE may not run. Re-grant in Settings."
            Log.w(TAG, "Permissions still missing after request; starting service anyway")
            launch()
        }
    }

    private fun launch() {
        status.text = "Dual-role BLE running. Grep logcat:  adb logcat -s HOPLOG"
        BleService.start(this)
        requestBatteryExemption()
    }

    // Aggressive OEMs reap non-exempt FGSs; prompt the user once to exempt this app.
    private fun requestBatteryExemption() {
        if (batteryPromptShown) return
        val pm = getSystemService(PowerManager::class.java) ?: return
        if (!pm.isIgnoringBatteryOptimizations(packageName)) {
            batteryPromptShown = true
            try {
                startActivity(
                    Intent(
                        Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                        Uri.parse("package:$packageName"),
                    ),
                )
            } catch (e: Exception) {
                Log.w(TAG, "battery-exemption prompt failed: ${e.message}")
            }
        }
    }

    private var batteryPromptShown = false

    companion object {
        private const val REQ = 7001
    }
}
