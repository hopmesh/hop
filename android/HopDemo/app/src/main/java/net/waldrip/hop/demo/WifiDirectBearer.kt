package net.waldrip.hop.demo

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pManager
import android.net.wifi.p2p.nsd.WifiP2pDnsSdServiceInfo
import android.net.wifi.p2p.nsd.WifiP2pDnsSdServiceRequest
import android.os.Build
import android.os.Handler
import android.util.Log
import java.net.InetSocketAddress
import java.net.Socket
import kotlin.concurrent.thread

/**
 * Wi-Fi Direct (Wi-Fi P2P) bearer — links Android↔Android over Wi-Fi when there is NO shared
 * network/router. It mirrors the LAN bearer's contract: once a peer-to-peer group forms, both
 * devices have IP connectivity over the `p2p` interface and talk plain TCP with the same
 * length-prefix framing ([LanLink]). The group owner accepts on the shared [HopBearer] TCP server
 * (bound 0.0.0.0, so the p2p interface is covered); the client dials the group owner here.
 *
 * Discovery is Bonjour-over-P2P (DNS-SD): each device advertises a local service whose instance
 * name is its base58 address, and browses for peers'. To avoid both sides initiating a group at
 * once, only the device with the lexicographically lower base58 address calls `connect()`.
 *
 * Wi-Fi Direct is notoriously OEM-dependent and the first connection may surface a system pairing
 * prompt; failures are caught and discovery retries on the periodic loop.
 */
class WifiDirectBearer(
    private val context: Context,
    private val main: Handler,
    private val myAddr: () -> String,
    private val serverPort: Int,
    private val alreadyLinked: (String) -> Boolean,   // peer base58 already directly linked (e.g. NSD)?
    // Whether Wi-Fi Direct should be active right now. It's only useful with NO shared network — on
    // Wi-Fi, NSD/LAN already links Android↔Android, and P2P social-channel scanning otherwise thrashes
    // the 2.4 GHz radio nonstop (starving BLE → LMP timeouts/churn, plus battery/heat). So gate it off
    // whenever we're on a Wi-Fi network.
    private val shouldRun: () -> Boolean,
    private val onClientSocket: (Socket) -> Unit,
) {
    private var manager: WifiP2pManager? = null
    private var channel: WifiP2pManager.Channel? = null
    private var receiver: BroadcastReceiver? = null
    private var serviceRequest: WifiP2pDnsSdServiceRequest? = null
    @Volatile private var connecting = false
    @Volatile private var groupFormed = false
    private var dialedThisGroup = false
    private var active = false   // discovery/advertising currently running (radio in use)

    fun start() {
        if (!hasPermission()) { Log.w("HOPLOG", "wifi-direct: missing nearby/location permission"); return }
        val mgr = context.getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager ?: return
        manager = mgr
        channel = mgr.initialize(context, main.looper, null) ?: return
        setDiscoveryListeners()   // cheap: just sets callbacks; no radio use until activate()
        registerReceiver()
        startControlLoop()        // activates P2P only when shouldRun() (off-network)
        Log.i("HOPLOG", "wifi-direct ready: ${myAddr().take(8)} (activates only off-network)")
    }

    fun stop() {
        receiver?.let { runCatching { context.unregisterReceiver(it) } }
        receiver = null
        val mgr = manager; val ch = channel
        if (mgr != null && ch != null) {
            runCatching { mgr.clearLocalServices(ch, null) }
            runCatching { mgr.clearServiceRequests(ch, null) }
        }
    }

    // ---- discovery callbacks (set once; no radio use) ----
    private fun setDiscoveryListeners() {
        val mgr = manager ?: return; val ch = channel ?: return
        mgr.setDnsSdResponseListeners(ch,
            { instanceName, _, srcDevice ->
                // instanceName is the peer's base58 address.
                main.post {
                    if (instanceName == myAddr()) return@post              // ignore ourselves
                    if (myAddr() >= instanceName) return@post              // tiebreak: lower base58 connects
                    if (connecting || groupFormed) return@post            // one group at a time
                    if (alreadyLinked(instanceName)) return@post          // already linked (e.g. shared Wi-Fi via NSD)
                    connectTo(srcDevice.deviceAddress, instanceName)
                }
            },
            { _, _, _ -> /* TXT record — we only need the port, which is fixed */ },
        )
    }

    /// Begin advertising our service + scanning for peers — only call when off-network. This is what
    /// puts the 2.4 GHz radio to work, so it must stay off whenever Wi-Fi (LAN) can do the job.
    private fun activate() {
        val mgr = manager ?: return; val ch = channel ?: return
        if (!hasPermission()) return
        val info = WifiP2pDnsSdServiceInfo.newInstance(
            myAddr(), HopBearer.LAN_SERVICE, mapOf("port" to serverPort.toString()),
        )
        runCatching { mgr.addLocalService(ch, info, null) }
        val req = WifiP2pDnsSdServiceRequest.newInstance()
        serviceRequest = req
        runCatching { mgr.addServiceRequest(ch, req, null) }
        runCatching { mgr.discoverServices(ch, null) }
        active = true
        Log.i("HOPLOG", "wifi-direct ACTIVE (off-network)")
    }

    /// Quiesce Wi-Fi Direct entirely so the 2.4 GHz radio is free for BLE + Wi-Fi.
    private fun deactivate() {
        val mgr = manager ?: return; val ch = channel ?: return
        runCatching { mgr.clearLocalServices(ch, null) }
        runCatching { mgr.clearServiceRequests(ch, null) }
        runCatching { mgr.stopPeerDiscovery(ch, null) }
        serviceRequest = null
        active = false
        Log.i("HOPLOG", "wifi-direct quiesced (on-network)")
    }

    private fun connectTo(deviceAddress: String, peerName: String) {
        val mgr = manager ?: return; val ch = channel ?: return
        if (!hasPermission()) return
        val config = WifiP2pConfig().apply {
            this.deviceAddress = deviceAddress
            wps.setup = android.net.wifi.WpsInfo.PBC
        }
        connecting = true
        runCatching {
            mgr.connect(ch, config, object : WifiP2pManager.ActionListener {
                override fun onSuccess() { Log.i("HOPLOG", "wifi-direct connect → ${peerName.take(8)}") }
                override fun onFailure(reason: Int) { connecting = false; Log.w("HOPLOG", "wifi-direct connect failed $reason") }
            })
        }.onFailure { connecting = false }
    }

    // ---- connection lifecycle ----
    private fun registerReceiver() {
        val filter = IntentFilter().apply {
            addAction(WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION)
        }
        val r = object : BroadcastReceiver() {
            override fun onReceive(c: Context?, intent: Intent?) {
                when (intent?.action) {
                    WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION -> onConnectionChanged()
                }
            }
        }
        receiver = r
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(r, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(r, filter)
        }
    }

    private fun onConnectionChanged() {
        val mgr = manager ?: return; val ch = channel ?: return
        mgr.requestConnectionInfo(ch) { info ->
            if (!info.groupFormed) {
                groupFormed = false; connecting = false; dialedThisGroup = false
                return@requestConnectionInfo
            }
            groupFormed = true; connecting = false
            if (info.isGroupOwner) {
                // The shared TCP server (0.0.0.0:serverPort) accepts the client — nothing to do here.
                Log.i("HOPLOG", "wifi-direct group owner — awaiting client")
            } else if (!dialedThisGroup) {
                dialedThisGroup = true
                val host = info.groupOwnerAddress ?: return@requestConnectionInfo
                thread(name = "wifi-direct-dial") {
                    val sock = runCatching {
                        Socket().apply { connect(InetSocketAddress(host, serverPort), 6000) }
                    }.getOrNull()
                    if (sock != null) {
                        Log.i("HOPLOG", "wifi-direct dialed GO $host")
                        onClientSocket(sock)
                    } else {
                        main.post { dialedThisGroup = false }
                    }
                }
            }
        }
    }

    // ---- control loop: run P2P only off-network; re-trigger discovery while active ----
    private fun startControlLoop() {
        main.post(object : Runnable {
            override fun run() {
                val mgr = manager; val ch = channel
                if (mgr != null && ch != null && hasPermission()) {
                    val want = shouldRun()
                    if (want && !active && !groupFormed) {
                        activate()
                    } else if (!want && active) {
                        deactivate()
                    } else if (want && active && !groupFormed) {
                        runCatching { mgr.discoverServices(ch, null) }   // keep discovery fresh
                    }
                }
                main.postDelayed(this, 15_000)
            }
        })
    }

    private fun hasPermission(): Boolean {
        val perm = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU)
            Manifest.permission.NEARBY_WIFI_DEVICES else Manifest.permission.ACCESS_FINE_LOCATION
        return context.checkSelfPermission(perm) == PackageManager.PERMISSION_GRANTED
    }
}
