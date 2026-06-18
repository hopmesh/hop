package net.waldrip.hop.demo

import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors
import kotlin.concurrent.thread
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import uniffi.hop_ffi.HopNode
import uniffi.hop_ffi.addressBase58

/**
 * Foreground Android BLE bearer for Hop: each device acts as both peripheral
 * (advertise the shared Hop service UUID + accept L2CAP) and central (scan + open
 * L2CAP), carrying the node's byte packets over L2CAP CoC. Mirrors the iOS bearer;
 * does no protocol work — just shuttles bytes via connected/received/drainOutgoing.
 */
@SuppressLint("MissingPermission")
class HopBearer private constructor(private val context: Context) {

    data class Peer(
        val address: ByteArray, val name: String, val hops: UByte,
        val active: Boolean = true, val platform: String = "", val app: String = "",
    )
    data class Message(
        val localId: Long, val peer: String, val text: String, val incoming: Boolean,
        val bundleId: ByteArray? = null,
        val hops: UByte = 0u, val latencyMs: ULong? = null,           // incoming metadata
        val sentAt: Long = System.currentTimeMillis(),               // outgoing tracking
        val deliveredAt: Long? = null, val relayed: UInt = 0u,
        val delivered: Boolean = false, val deliveryHops: UByte = 0u,
    )

    // Identity derived from the device (stable, storage-independent — §4); the db path
    // persists messages across restarts.
    val node: HopNode = HopNode.`open`(
        java.io.File(context.filesDir, "hop.db").absolutePath,
        deviceSeed(context),
    )
    val peers = mutableStateListOf<Peer>()
    val messages = mutableStateListOf<Message>()
    val secured = mutableStateListOf<List<Byte>>()   // addresses with a forward-secret session
    var myAddress = mutableStateOf("")
    var myName = mutableStateOf("")
    var status = mutableStateOf("starting…")
    var relayStatus = mutableStateOf("not connected")
    private var nextMsgId = 0L
    private var appActive = true
    private val appName: String =
        context.applicationInfo.loadLabel(context.packageManager).toString()

    private val main = Handler(Looper.getMainLooper())
    private val adapter: BluetoothAdapter by lazy {
        (context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
    }
    private val links = HashMap<ULong, HopLink>()
    private var nextLinkId: ULong = 1u
    private var psm: Int = -1
    private var serverSocket: BluetoothServerSocket? = null
    private var gattServer: BluetoothGattServer? = null
    private val connecting = HashSet<String>()
    private val nameByAddr = HashMap<List<Byte>, String>()

    // Cloud relay bearer — reaches a hop-relayd over the internet (DESIGN.md §19, §21).
    // WebSocket (path B, wss:// → Cloud Run) and raw TCP (path A, the VM) share one
    // link id; each link packet is one WS binary frame, or a 4-byte length-prefixed
    // TCP frame matching the daemon.
    private val relayLinkId: ULong = 20_000u
    private var relayWS: WebSocket? = null
    private var relaySocket: java.net.Socket? = null
    private var relayOut: java.io.OutputStream? = null
    private var relayWriter: java.util.concurrent.ExecutorService? = null
    @Volatile private var relayConnected = false

    @Volatile var appInForeground = false
    private var started = false

    fun start(name: String) {
        if (started) return
        started = true
        ensureNotificationChannel()
        myName.value = name
        myAddress.value = addressBase58(node.address())
        // Presence is an app-level service (DESIGN.md §23): publish our name on the
        // "presence" topic and subscribe so discovered records are retained.
        runCatching { node.subscribe(PRESENCE_SERVICE) }
        publishPresence()
        // Publish our prekey once so peers can open forward-secret sessions (§25);
        // link-up gossip re-offers it, so no periodic re-publish is needed.
        runCatching { node.publishPrekey() }
        startPeripheral()
        startCentral()
        var ticks = 0
        main.postDelayed(object : Runnable {
            override fun run() {
                node.tick(nowMs())
                if (++ticks % 20 == 0) publishPresence()
                pump()
                main.postDelayed(this, 1000)
            }
        }, 1000)
    }

    /// Re-publish our presence advert so it stays within TTL and renames propagate.
    /// `summary` carries app-level metadata: "state|platform|app".
    private fun publishPresence() {
        val meta = "${if (appActive) "fg" else "bg"}|android|$appName"
        runCatching {
            node.publishService(PRESENCE_SERVICE, myName.value, meta, emptyList(), PRESENCE_TTL_MS)
        }
    }

    /// The host activity calls this on resume/pause; we re-publish presence so peers
    /// see our current foreground/background state.
    fun setForeground(fg: Boolean) {
        appActive = fg
        appInForeground = fg
        main.post { publishPresence(); pump() }
    }

    fun send(text: String, to: Peer) {
        val id = runCatching {
            node.sendMessage(to.address, "text/plain", text.toByteArray(), true)
        }.getOrNull()
        messages.add(Message(localId = nextMsgId++, peer = to.name, text = text, incoming = false, bundleId = id))
        pump()
    }

    // ---- node <-> radio plumbing (all on the main thread) -------------------

    private fun addLink(socket: BluetoothSocket, initiator: Boolean) = main.post {
        val id = nextLinkId++
        val link = HopLink(id, socket,
            onBytes = { lid, data -> main.post { node.received(lid, data); pump() } },
            onClose = { lid -> main.post { links.remove(lid); node.disconnected(lid); refresh() } })
        links[id] = link
        node.connected(id, initiator)
        status.value = "linked (${if (initiator) "central" else "peripheral"})"
        pump()
    }

    private fun pump() {
        for (pkt in node.drainOutgoing()) {
            val link = links[pkt.link]
            if (link != null) link.send(pkt.bytes)
            else if (pkt.link == relayLinkId) relaySend(pkt.bytes)
        }
        refresh()
        for (m in node.takeInbox()) {
            val who = nameByAddr[m.from.toList()] ?: shortHex(m.from)
            val text = String(m.body)
            val now = nowMs()
            val latency = if (now >= m.createdAt) now - m.createdAt else 0uL
            messages.add(Message(localId = nextMsgId++, peer = who, text = text,
                incoming = true, hops = m.hops, latencyMs = latency))
            if (!appInForeground) notify(who, text)
        }
    }

    // ---- cloud relay bearer (→ hop-relayd) ----------------------------------

    /// Connect to a `hop-relayd`. Accepts a `host:port` (raw TCP, path A) or a
    /// `ws://`/`wss://` URL (WebSocket, path B). The device dials → Noise initiator.
    fun connectRelay(input: String) {
        val t = input.trim()
        if (t.startsWith("ws://") || t.startsWith("wss://")) connectRelayWS(t)
        else connectRelayTcp(t)
    }

    private fun connectRelayWS(url: String) {
        teardownRelay()
        relayStatus.value = "connecting…"
        val client = OkHttpClient.Builder().build()
        relayWS = client.newWebSocket(Request.Builder().url(url).build(), object : WebSocketListener() {
            override fun onOpen(ws: WebSocket, response: Response) { main.post {
                relayStatus.value = "connected"; relayConnected = true
                node.connected(relayLinkId, true); pump()
            } }
            override fun onMessage(ws: WebSocket, bytes: ByteString) { main.post {
                node.received(relayLinkId, bytes.toByteArray()); pump()   // one frame = one packet
            } }
            override fun onClosing(ws: WebSocket, code: Int, reason: String) { main.post {
                relayStatus.value = "disconnected"; relayDown()
            } }
            override fun onFailure(ws: WebSocket, t: Throwable, response: Response?) { main.post {
                relayStatus.value = "failed: ${t.message}"; relayDown()
            } }
        })
    }

    private fun connectRelayTcp(hostPort: String) {
        val parts = hostPort.split(":")
        val port = parts.getOrNull(1)?.toIntOrNull()
        if (parts.size != 2 || port == null) { relayStatus.value = "bad address"; return }
        teardownRelay()
        relayStatus.value = "connecting…"
        thread(isDaemon = true) {
            try {
                val sock = java.net.Socket(parts[0], port).apply { tcpNoDelay = true }
                relaySocket = sock
                relayOut = sock.getOutputStream()
                relayWriter = Executors.newSingleThreadExecutor()
                val inp = java.io.DataInputStream(sock.getInputStream())
                main.post {
                    relayStatus.value = "connected"; relayConnected = true
                    node.connected(relayLinkId, true); pump()
                }
                val hdr = ByteArray(4)
                while (true) {
                    inp.readFully(hdr)
                    val n = (hdr[0].toInt() and 0xff shl 24) or (hdr[1].toInt() and 0xff shl 16) or
                            (hdr[2].toInt() and 0xff shl 8) or (hdr[3].toInt() and 0xff)
                    if (n <= 0 || n > (1 shl 20)) break
                    val buf = ByteArray(n); inp.readFully(buf)
                    main.post { node.received(relayLinkId, buf); pump() }
                }
            } catch (_: Exception) {
                main.post { if (relayStatus.value == "connected") relayStatus.value = "disconnected" }
            } finally {
                main.post { relayDown() }
            }
        }
    }

    private fun relaySend(bytes: ByteArray) {
        relayWS?.let { it.send(ByteString.of(*bytes)); return }   // OkHttp send is thread-safe
        val out = relayOut ?: return
        relayWriter?.execute {
            try {
                val n = bytes.size
                val frame = ByteArray(4 + n)
                frame[0] = (n ushr 24).toByte(); frame[1] = (n ushr 16).toByte()
                frame[2] = (n ushr 8).toByte(); frame[3] = n.toByte()
                System.arraycopy(bytes, 0, frame, 4, n)
                out.write(frame); out.flush()
            } catch (_: Exception) {}
        }
    }

    /// Drop transport handles and tell the node the link is down (idempotent).
    private fun relayDown() {
        if (relayConnected) { relayConnected = false; node.disconnected(relayLinkId); pump() }
        relayWriter?.shutdownNow(); relayWriter = null
        runCatching { relaySocket?.close() }
        relaySocket = null; relayOut = null; relayWS = null
    }

    private fun teardownRelay() {
        relayWS?.cancel()
        relayWriter?.shutdownNow(); relayWriter = null
        runCatching { relaySocket?.close() }
        relaySocket = null; relayOut = null; relayWS = null
        if (relayConnected) { relayConnected = false; node.disconnected(relayLinkId) }
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(CHANNEL_ID, "Hop messages", NotificationManager.IMPORTANCE_DEFAULT)
            context.getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    private fun notify(from: String, text: String) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
            android.content.pm.PackageManager.PERMISSION_GRANTED
        ) return
        val n = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_email)
            .setContentTitle(from)
            .setContentText(text)
            .setAutoCancel(true)
            .build()
        NotificationManagerCompat.from(context).notify(text.hashCode(), n)
    }

    private fun refresh() {
        val mine = node.address().toList()
        // Collapse the many retained presence adverts per publisher: nearest hops for
        // distance, newest advert (max createdAt) for current name/state/platform/app.
        data class Agg(var minHops: UByte, var newestAt: ULong, var peer: Peer)
        val agg = HashMap<List<Byte>, Agg>()
        for (p in node.browse(PRESENCE_SERVICE, "")) {
            val key = p.publisher.toList()
            if (key == mine) continue
            val name = p.title.ifEmpty { shortHex(p.publisher) }
            val parts = p.summary.split("|")
            val active = parts.getOrNull(0) != "bg"
            val platform = parts.getOrNull(1) ?: ""
            val app = parts.getOrNull(2) ?: ""
            val ex = agg[key]
            val hops = if (ex != null && ex.minHops < p.hops) ex.minHops else p.hops
            if (ex == null || p.createdAt >= ex.newestAt) {
                agg[key] = Agg(hops, p.createdAt, Peer(p.publisher, name, hops, active, platform, app))
            } else {
                ex.minHops = hops
            }
            nameByAddr[key] = name
        }
        val list = agg.values.map { it.peer.copy(hops = it.minHops) }
            .sortedWith(compareBy({ it.hops }, { it.name }))
        peers.clear(); peers.addAll(list)

        // Which peers we're talking to over a forward-secret session (lock icon).
        secured.clear()
        secured.addAll(list.filter { node.isSecured(it.address) }.map { it.address.toList() })

        // Delivery status for our outgoing messages.
        for (i in messages.indices) {
            val m = messages[i]
            if (m.incoming || m.bundleId == null) continue
            val s = node.messageStatus(m.bundleId)
            if (s.delivered && m.deliveredAt == null) {
                messages[i] = m.copy(relayed = s.relayed, delivered = true,
                    deliveryHops = s.deliveryHops, deliveredAt = System.currentTimeMillis())
            } else if (s.relayed != m.relayed) {
                messages[i] = m.copy(relayed = s.relayed)
            }
        }
    }

    // ---- peripheral: advertise + accept L2CAP -------------------------------

    private fun startPeripheral() {
        val ss = adapter.listenUsingInsecureL2capChannel()
        serverSocket = ss
        psm = ss.psm
        thread(name = "hop-accept") {
            while (true) {
                val socket = runCatching { ss.accept() }.getOrNull() ?: break
                addLink(socket, initiator = false)
            }
        }

        val server = (context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager)
            .openGattServer(context, gattServerCallback)
        val service = BluetoothGattService(SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        service.addCharacteristic(
            BluetoothGattCharacteristic(
                PSM_CHAR_UUID,
                BluetoothGattCharacteristic.PROPERTY_READ,
                BluetoothGattCharacteristic.PERMISSION_READ,
            )
        )
        server.addService(service)
        gattServer = server

        adapter.bluetoothLeAdvertiser?.startAdvertising(
            AdvertiseSettings.Builder()
                .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
                .setConnectable(true)
                .build(),
            AdvertiseData.Builder().addServiceUuid(ParcelUuid(SERVICE_UUID)).build(),
            advertiseCallback,
        )
        status.value = "advertising (psm $psm)"
    }

    private val gattServerCallback = object : BluetoothGattServerCallback() {
        override fun onCharacteristicReadRequest(
            device: BluetoothDevice, requestId: Int, offset: Int,
            characteristic: BluetoothGattCharacteristic,
        ) {
            val value = if (characteristic.uuid == PSM_CHAR_UUID) {
                byteArrayOf(
                    (psm ushr 24).toByte(), (psm ushr 16).toByte(),
                    (psm ushr 8).toByte(), psm.toByte(),
                )
            } else ByteArray(0)
            gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
        }
    }

    private val advertiseCallback = object : AdvertiseCallback() {}

    // ---- central: scan + open L2CAP -----------------------------------------

    private fun startCentral() {
        val scanner = adapter.bluetoothLeScanner ?: return
        val filter = ScanFilter.Builder().setServiceUuid(ParcelUuid(SERVICE_UUID)).build()
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        scanner.startScan(listOf(filter), settings, scanCallback)
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val device = result.device
            if (!connecting.add(device.address)) return
            device.connectGatt(context, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
        }
    }

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, statusCode: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED) gatt.discoverServices()
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, statusCode: Int) {
            val ch = gatt.getService(SERVICE_UUID)?.getCharacteristic(PSM_CHAR_UUID) ?: return
            gatt.readCharacteristic(ch)
        }

        @Deprecated("compat with API < 33")
        override fun onCharacteristicRead(
            gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, statusCode: Int,
        ) {
            val v = characteristic.value ?: return
            if (v.size < 4) return
            val psm = (v[0].toInt() and 0xff shl 24) or (v[1].toInt() and 0xff shl 16) or
                (v[2].toInt() and 0xff shl 8) or (v[3].toInt() and 0xff)
            val device = gatt.device
            thread(name = "hop-l2cap-connect") {
                val socket = runCatching {
                    device.createInsecureL2capChannel(psm).apply { connect() }
                }.getOrNull() ?: return@thread
                addLink(socket, initiator = true)
            }
        }
    }

    companion object {
        val SERVICE_UUID: UUID = UUID.fromString("F0900000-0000-4000-8000-000000000000")
        val PSM_CHAR_UUID: UUID = UUID.fromString("F0900001-0000-4000-8000-000000000000")
        const val CHANNEL_ID = "hop.messages"
        const val PRESENCE_SERVICE = "presence"
        const val PRESENCE_TTL_MS: UInt = 600_000u

        @Volatile private var inst: HopBearer? = null

        /// One shared instance, owned by the foreground service and observed by the UI.
        fun shared(context: Context): HopBearer =
            inst ?: synchronized(this) {
                inst ?: HopBearer(context.applicationContext).also { inst = it }
            }

        fun nowMs(): ULong = System.currentTimeMillis().toULong()

        /// Compact base58 prefix for display (full base58 via `addressBase58`).
        fun shortHex(d: ByteArray): String = addressBase58(d).take(8)

        /// 32-byte Ed25519 seed derived from the device (stable, storage-free — §4).
        fun deviceSeed(context: Context): ByteArray {
            val androidId = android.provider.Settings.Secure.getString(
                context.contentResolver, android.provider.Settings.Secure.ANDROID_ID
            ) ?: "hop-fallback"
            return java.security.MessageDigest.getInstance("SHA-256")
                .digest("hop.identity.v1|$androidId".toByteArray())
        }

        /// Compact elapsed-time label: 3s / 5m / 2h / 4d.
        fun compactDuration(ms: ULong): String {
            val s = ms / 1000u
            if (s < 60u) return "${s}s"
            val m = s / 60u
            if (m < 60u) return "${m}m"
            val h = m / 60u
            if (h < 24u) return "${h}h"
            return "${h / 24u}d"
        }

        /// A single link is "direct" (0 relays); ≥2 shows the count.
        fun hopsLabel(h: UByte): String = if (h.toInt() <= 1) "direct" else "$h hops"
    }
}
