package sh.hopme.blelab

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.bluetooth.BluetoothAdapter
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import sh.hopme.bearers.BearerManager
import sh.hopme.bearers.randomNodeId
import sh.hopme.bearers.ble.BleBearer
import sh.hopme.bearers.lan.LanBearer
import sh.hopme.bearers.wifidirect.WifiDirectBearer

// Foreground service that hosts BOTH BLE planes for the whole session and rebuilds them on an
// adapter bounce WITHOUT re-rolling myId (SPEC §6 / §9 R11).
class BleService : Service() {

    // The transport layer, driven entirely through the Bearer contract: a BearerManager fanning out to
    // a single BleBearer, with the clean-room ProofSink wired in as the consumer. Rebuilt on an adapter
    // bounce; the ProofSink (and the stable myId) persist across rebuilds.
    private var manager: BearerManager? = null
    private val proof = ProofSink()
    private var receiver: BroadcastReceiver? = null

    override fun onCreate() {
        super.onCreate()
        isRunning = true
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIF_ID, buildNotification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        } else {
            startForeground(NOTIF_ID, buildNotification())
        }
        startNode()
        registerAdapterReceiver()
        AnchorWatchdogReceiver.schedule(this) // keep the anchor self-resurrecting (BACKGROUND.md §7)
    }

    private fun startNode() {
        if (manager != null) return
        try {
            val m = BearerManager()
            // Register every transport against the SAME process-stable nodeId (R11) — one identity
            // across radios. The manager fans start/stop/send out to both and multiplexes their links
            // into one global LinkId space behind the single ProofSink.
            m.register(BleBearer(applicationContext, myId))
            m.register(LanBearer(applicationContext, myId))
            // Wi-Fi Direct (Android-only): peer-to-peer Wi-Fi when there's no shared router. Same nodeId,
            // same global LinkId space, same ProofSink — one more radio behind the uniform Bearer contract.
            m.register(WifiDirectBearer(applicationContext, myId))
            proof.bearer = m   // proof pings route out through the manager (uniform Bearer)
            m.sink = proof     // links from every registered bearer surface here, one id space
            m.start()
            manager = m
        } catch (e: Exception) {
            Log.e(TAG, "NODE START failed: ${e.message}", e)
        }
    }

    private fun registerAdapterReceiver() {
        val r = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action != BluetoothAdapter.ACTION_STATE_CHANGED) return
                when (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)) {
                    BluetoothAdapter.STATE_OFF -> {
                        Log.i(TAG, "ADAPTER STATE_OFF → closing all links, tearing down planes")
                        manager?.stop()
                        manager = null
                    }
                    BluetoothAdapter.STATE_ON -> {
                        Log.i(TAG, "ADAPTER STATE_ON → rebuilding both planes (myId unchanged)")
                        startNode() // myId is a process-lifetime global; NOT re-rolled (R11)
                    }
                }
            }
        }
        registerReceiver(r, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED))
        receiver = r
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_STICKY

    override fun onDestroy() {
        super.onDestroy()
        isRunning = false
        // Do NOT cancel the watchdog alarm here — if we were killed (not force-stopped), let it fire
        // and resurrect us so the iBeacon comes back to wake a killed iOS peer.
        receiver?.let { try { unregisterReceiver(it) } catch (_: Exception) {} }
        manager?.stop()
        manager = null
        proof.shutdown()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun buildNotification(): Notification {
        val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(CHANNEL_ID, "BLE Lab", NotificationManager.IMPORTANCE_LOW)
            mgr.createNotificationChannel(ch)
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("BLE Lab")
            .setContentText("Dual-role BLE proof-of-pipe running")
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "ble_lab"
        private const val NOTIF_ID = 1

        // Process-static liveness flag. Reset to false in a fresh process (after a kill), so the
        // watchdog correctly restarts the FGS when the alarm wakes a dead app.
        @Volatile var isRunning = false

        // SPEC §1.2 / R11: the 16-byte nodeId, created ONCE per process and reused on every rebuild
        // (an adapter bounce must NOT re-roll it). id-gen now lives in :bearer-core (one identity shared
        // across transports); the app owns its lifetime and hands it to every bearer it builds.
        val myId: ByteArray = randomNodeId()

        fun start(ctx: Context) {
            val i = Intent(ctx, BleService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                ctx.startForegroundService(i)
            } else {
                ctx.startService(i)
            }
        }
    }
}
