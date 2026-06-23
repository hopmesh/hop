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
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.snapshots.SnapshotStateList
import uniffi.hop_ffi.HopNode
import uniffi.hop_ffi.HnsLookupResult
import uniffi.hop_ffi.HpsKind
import uniffi.hop_ffi.TraceHopInfo
import uniffi.hop_ffi.addressBase58
import uniffi.hop_ffi.addressFromBase58
import uniffi.hop_ffi.decodeIdentity
import uniffi.hop_ffi.serviceIdentify

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
        val contentType: String = "text/plain",
        val imageData: ByteArray? = null,                            // set for a single image/* message
        val images: List<ByteArray> = emptyList(),                   // one+ images of a multipart message
        val hops: UByte = 0u, val latencyMs: ULong? = null,           // incoming metadata
        val trace: List<String> = emptyList(),                        // provenance hop labels (§27)
        val sentAt: Long = System.currentTimeMillis(),               // outgoing tracking
        val deliveredAt: Long? = null, val relayed: UInt = 0u,
        val delivered: Boolean = false, val deliveryHops: UByte = 0u,
        val failed: Boolean = false,   // gave up (e.g. the queue was cleared before it sent)
    )

    // Identity derived from the device (stable, storage-independent — §4); the db path
    // persists messages across restarts.
    val node: HopNode = HopNode.`open`(
        java.io.File(context.filesDir, "hop.db").absolutePath,
        deviceSeed(context),
        APP_SECRET,
    )
    val peers = mutableStateListOf<Peer>()
    /// Directly-linked peer address → the transport carrying it ("BT" / "Relay"); mesh peers
    /// (reached multi-hop) have no entry. Mirrors iOS's link-type indicators.
    val linkTransports = mutableStateMapOf<List<Byte>, String>()
    val messages = mutableStateListOf<Message>()
    /// Unread incoming messages received while backgrounded — mirrored onto the app icon
    /// badge (via the notification) and cleared when the app returns to the foreground.
    val unread = androidx.compose.runtime.mutableIntStateOf(0)
    val secured = mutableStateListOf<List<Byte>>()   // addresses with a forward-secret session

    // hops:// (DESIGN.md §30): domain → rendered result; pending resolves + outstanding requests.
    val hopsResults = mutableStateMapOf<String, String>()
    private val pendingHops = HashMap<String, String>()              // domain → path awaiting resolve
    private val hopsReqs = HashMap<List<Byte>, String>()             // request id → domain
    private val dohClient = OkHttpClient()
    // HNS cache debug view: domain → (address, ttl).
    val hnsCache = mutableStateListOf<HnsCacheRow>()
    data class HnsCacheRow(val domain: String, val address: ByteArray, val ttlSecs: UInt)

    // hps:// pub/sub (DESIGN.md §32): topics we host/subscribe, per-topic threads, unread, invites.
    val hpsTopics = mutableStateListOf<HpsTopic>()
    val hpsThreads = mutableStateMapOf<String, SnapshotStateList<HpsMsg>>() // topic id → messages
    val hpsUnread = mutableStateMapOf<String, Int>()                        // topic id → unread
    val hpsInvites = mutableStateListOf<uniffi.hop_ffi.HpsInvite>()         // invites received
    @Volatile var activeTopic: String? = null                              // topic on screen

    // Diagnostics (Status tab) — parity with iOS: service-call log + relay queue.
    val serviceLog = mutableStateListOf<String>()
    val queue = mutableStateListOf<QueueRow>()
    data class QueueRow(val own: Boolean, val to: String, val priority: UByte, val hops: UByte)
    private val identifyAsked = HashSet<List<Byte>>()   // addresses we've sent hop.identify to
    private val identifyReqs = HashSet<List<Byte>>()    // outstanding identify request ids
    data class HpsTopic(
        val host: ByteArray, val path: String, val channel: Boolean, val hosting: Boolean,
        val access: uniffi.hop_ffi.HpsAccess = uniffi.hop_ffi.HpsAccess.OPEN,
    ) {
        val id: String get() = addressBase58(host) + "/" + path
        val writable: Boolean get() = channel || hosting
    }
    data class HpsMsg(val id: Long, val path: String, val sender: ByteArray, val text: String)
    var myAddress = mutableStateOf("")
    var myName = mutableStateOf("")
    var status = mutableStateOf("starting…")
    var relayStatus = mutableStateOf("not connected")
    private val prefs get() = context.getSharedPreferences("hop", android.content.Context.MODE_PRIVATE)
    /// A relay the user pinned by direct address (persisted). A device only ever talks to ONE
    /// relay — routing is anycast — so pinning overrides the anycast default for testing a
    /// specific relay, rather than publishing presence to several at once.
    val pinnedRelay = mutableStateOf<String?>(null)
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
    private var lastPeerLinkCount = -1
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
    private var relayUrl: String? = null          // last relay endpoint, for auto check-in
    private var lastRelayDialMs: ULong = 0u       // throttle reconnect attempts

    @Volatile var appInForeground = false
    private var started = false

    fun start(name: String) {
        if (started) return
        started = true
        ensureNotificationChannel()
        loadMessages()      // restore chat history from the previous run
        loadHpsChannels()   // restore channel (hps) message threads
        loadHpsTopics()     // restore hosted/subscribed channels (the node persists them)
        myName.value = name
        myAddress.value = addressBase58(node.address())
        // Presence is an app-level service (DESIGN.md §23): publish our name on the
        // "presence" topic and subscribe so discovered records are retained.
        runCatching { node.subscribe(PRESENCE_SERVICE) }
        // Set the node clock to real time BEFORE publishing any adverts. The node starts at
        // now_ms=0 and the first tick runs directory.expire(), so a prekey/presence advert
        // stamped created_at=0 here is judged expired (1970 + TTL) and dropped instantly.
        // Presence re-publishes and recovers; the prekey is published once, so without this no
        // peer ever learns our prekey and every message defers forever ("Sending…"). (§25)
        runCatching { node.tick(nowMs()) }
        publishPresence()
        // Publish our prekey so peers can open forward-secret sessions (§25). Re-published
        // periodically in the tick loop too, so a lapsed/late neighbour can always re-open one.
        runCatching { node.publishPrekey() }
        startPeripheral()
        startCentral()
        // Declare internet reachability so the node resolves HNS itself by servicing
        // takeDnsLookups() (DESIGN.md §30). Track the default network so it stays accurate.
        val cm = context.getSystemService(android.net.ConnectivityManager::class.java)
        runCatching {
            val net = cm?.activeNetwork
            val caps = net?.let { cm.getNetworkCapabilities(it) }
            node.setInternet(caps?.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET) == true)
            cm?.registerDefaultNetworkCallback(object : android.net.ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: android.net.Network) { main.post { node.setInternet(true); pump() } }
                override fun onLost(network: android.net.Network) { main.post { node.setInternet(false) } }
            })
        }
        // Check in to the backbone (DESIGN.md §28): dial the anycast relay so we pull any
        // queued mail and stay reachable across the internet. The foreground service keeps
        // this alive; the tick loop below reconnects it if it ever drops.
        pinnedRelay.value = prefs.getString("pinnedRelay", null)
        connectRelay(pinnedRelay.value ?: DEFAULT_RELAY)
        var ticks = 0
        main.postDelayed(object : Runnable {
            override fun run() {
                node.tick(nowMs())
                if (++ticks % 20 == 0) publishPresence()
                // Re-publish our prekey periodically so a neighbour whose cached copy lapsed
                // (or who arrived later) can always open a forward-secret session to us (§25).
                if (ticks % 120 == 0) runCatching { node.publishPrekey() }
                // Re-arm BLE advertising periodically. Android advertising can silently stop
                // (OEM doze/screen-off, or a wedged stack) while startAdvertising still reports
                // success — leaving us undiscoverable. Re-arming self-heals it without a manual
                // Bluetooth toggle. (Restarting advertising doesn't drop existing connections.)
                if (ticks % 180 == 0) runCatching { startAdvertise() }
                // Keep the relay connected: a foreground service runs continuously, so a
                // reconnect here means real-time background delivery, not just on next launch.
                // Throttled so a flapping link doesn't hammer the dial (§28).
                if (!relayConnected && relayStatus.value != "connecting…") {
                    val now = nowMs()
                    if (now - lastRelayDialMs > 4000u) {
                        lastRelayDialMs = now
                        relayUrl?.let { connectRelay(it) }
                    }
                }
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
        if (fg) {   // the user is looking at the app → clear the unread badge + notifications
            unread.intValue = 0
            runCatching { NotificationManagerCompat.from(context).cancelAll() }
        }
        main.post { publishPresence(); pump() }
    }

    fun send(text: String, to: Peer) {
        val id = runCatching {
            node.sendMessage(to.address, "text/plain", text.toByteArray(), true)
        }.getOrNull()
        messages.add(Message(localId = nextMsgId++, peer = to.name, text = text, incoming = false, bundleId = id))
        pump()
    }

    /// Send an image — large bodies are transparently carrier-chunked + reassembled by core
    /// (DESIGN.md §20), same path as a text message but a binary content type.
    fun sendImage(data: ByteArray, to: Peer) {
        val id = runCatching {
            node.sendMessage(to.address, "image/jpeg", data, true)
        }.getOrNull()
        messages.add(Message(localId = nextMsgId++, peer = to.name, text = "", incoming = false,
            bundleId = id, contentType = "image/jpeg", imageData = data))
        pump()
    }

    /// Send text and/or one-or-more images as ONE message (multipart/mixed) — a single sealed
    /// payload (DESIGN.md §20/§32). Wire format shared with iOS:
    /// `[u32 partCount][ per part: u16 ctLen, ct, u32 bodyLen, body ]`.
    fun sendMultipart(text: String, images: List<ByteArray>, to: Peer) {
        val t = text.trim()
        val parts = ArrayList<Pair<String, ByteArray>>()
        if (t.isNotEmpty()) parts.add("text/plain" to t.toByteArray())
        for (img in images) parts.add("image/jpeg" to img)
        if (parts.isEmpty()) return
        val id = runCatching {
            node.sendMessage(to.address, "multipart/mixed", encodeMultipart(parts), true)
        }.getOrNull()
        messages.add(Message(localId = nextMsgId++, peer = to.name, text = t, incoming = false,
            bundleId = id, contentType = "multipart/mixed", images = images))
        pump()
    }

    /// Re-send a failed ("Not sent") message in place. Recovery for a message that gave up
    /// (queue cleared, or still unsent at a restart). `to` supplies the address (Message stores
    /// only the peer name).
    fun retry(m: Message, to: Peer) {
        if (m.incoming) return
        val ctBody: Pair<String, ByteArray> = when {
            m.contentType.startsWith("image/") -> {
                val d = m.imageData ?: return
                "image/jpeg" to d
            }
            m.contentType == "multipart/mixed" -> {
                val parts = ArrayList<Pair<String, ByteArray>>()
                if (m.text.isNotEmpty()) parts.add("text/plain" to m.text.toByteArray())
                val imgs = if (m.imageData != null) listOf(m.imageData) else m.images
                for (img in imgs) parts.add("image/jpeg" to img)
                if (parts.isEmpty()) return
                "multipart/mixed" to encodeMultipart(parts)
            }
            else -> "text/plain" to m.text.toByteArray()
        }
        val id = runCatching { node.sendMessage(to.address, ctBody.first, ctBody.second, true) }.getOrNull()
        val i = messages.indexOfFirst { it.localId == m.localId }
        if (i >= 0) messages[i] = m.copy(failed = false, delivered = false, bundleId = id,
            sentAt = System.currentTimeMillis())
        pump()
    }

    // ---- node <-> radio plumbing (all on the main thread) -------------------

    private fun addLink(socket: BluetoothSocket, initiator: Boolean) = main.post {
        val id = nextLinkId++
        val remoteAddr = runCatching { socket.remoteDevice?.address }.getOrNull()
        val link = HopLink(id, socket,
            onBytes = { lid, data -> main.post { node.received(lid, data); pump() } },
            onClose = { lid -> main.post {
                links.remove(lid)
                remoteAddr?.let { connecting.remove(it) }  // link dropped → allow a reconnect
                node.disconnected(lid); refresh()
            } })
        links[id] = link
        node.connected(id, initiator)
        android.util.Log.i("HOPLOG", "hop link UP id=$id initiator=$initiator remote=$remoteAddr")
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
            val isImage = m.contentType.startsWith("image/")
            val isMultipart = m.contentType == "multipart/mixed"
            var text = if (isImage) "" else String(m.body)
            var images: List<ByteArray> = emptyList()
            if (isMultipart) {
                val parts = decodeMultipart(m.body)
                text = parts.firstOrNull { it.first.startsWith("text/") }?.let { String(it.second) } ?: ""
                images = parts.filter { it.first.startsWith("image/") }.map { it.second }
            }
            val now = nowMs()
            val latency = if (now >= m.createdAt) now - m.createdAt else 0uL
            messages.add(Message(localId = nextMsgId++, peer = who, text = text,
                incoming = true, contentType = m.contentType,
                imageData = if (isImage) m.body else null, images = images,
                hops = m.hops, latencyMs = latency, trace = m.trace.map { traceLabel(it) }))
            queueIdentify(m.from)   // learn the sender's display name (§29)
            if (!appInForeground) {
                unread.intValue += 1
                notify(who, if (isImage) "📷 Photo" else text)
            }
        }
        saveMessages()
        drainHps()       // pub/sub messages (§32)
        drainHns()       // HNS lookups + hops:// responses (§30)
        drainServices()  // hop.identify replies + custom service calls (§29)
        refreshQueue()   // relay-queue diagnostics
    }

    // ---- services & diagnostics (DESIGN.md §29) ----------------------------

    /// hop.identify an address once per session so we learn its display name (its input, or a
    /// relay's domain). Resolves names in traces and the chat list.
    private fun queueIdentify(address: ByteArray) {
        val key = address.toList()
        if (!identifyAsked.add(key)) return
        runCatching { node.sendServiceRequest(address, serviceIdentify(), "", ByteArray(0)) }
            .getOrNull()?.let { identifyReqs.add(it.toList()) }
    }

    /// Resolve a trace hop to a label: us, a known name, else app-label + short id (§27).
    private fun traceLabel(h: TraceHopInfo): String {
        val name = nameByAddr[h.node.toList()]
        return name ?: "${h.appLabel} ${shortHex(h.node)}"
    }

    private fun drainServices() {
        for (resp in node.takeServiceResponses()) {
            val info = if (identifyReqs.remove(resp.forRequestId.toList()) && resp.status == 0u.toUShort())
                runCatching { decodeIdentity(resp.body) }.getOrNull() else null
            if (info != null) {
                val label = info.name.ifEmpty { shortHex(info.address) }
                nameByAddr[info.address.toList()] = label
                serviceLog.add(0, "identify ← $label (${info.kind})")
                refresh()
            } else {
                serviceLog.add(0, "service ← ${resp.status}: ${String(resp.body).take(120)}")
            }
        }
        for (req in node.takeServiceRequests()) {
            // No custom services in the demo — reply 501 so the caller isn't left hanging.
            serviceLog.add(0, "service → ${req.service}/${req.method} (501)")
            runCatching { node.sendServiceResponse(req.from, req.requestId, 501u, ByteArray(0)) }
        }
        if (serviceLog.size > 100) while (serviceLog.size > 100) serviceLog.removeAt(serviceLog.size - 1)
    }

    private fun refreshQueue() {
        queue.clear()
        for (q in node.queue()) {
            val to = if (q.to.isEmpty()) "egress" else shortHex(q.to)
            queue.add(QueueRow(q.own, to, q.priority, q.hops))
        }
    }

    fun clearQueue() {
        runCatching { node.clearQueue() }
        // Anything of ours still in flight is now abandoned — mark those "not sent" instead of
        // leaving them stuck on "Sending…".
        for (i in messages.indices) {
            val m = messages[i]
            if (!m.incoming && !m.delivered && !m.failed) messages[i] = m.copy(failed = true)
        }
        saveMessages()
        refreshQueue()
    }

    // ---- hps:// pub/sub (DESIGN.md §32) -------------------------------------

    fun hpsRegister(path: String, channel: Boolean,
                    access: uniffi.hop_ffi.HpsAccess = uniffi.hop_ffi.HpsAccess.OPEN,
                    discoverable: Boolean = false) {
        val p = path.trim(); if (p.isEmpty()) return
        runCatching {
            node.registerService(p, if (channel) HpsKind.CHANNEL else HpsKind.SERVICE, access,
                if (discoverable) uniffi.hop_ffi.HpsVisibility.DISCOVERABLE else uniffi.hop_ffi.HpsVisibility.PRIVATE)
        }
        if (hpsTopics.none { it.host.contentEquals(node.address()) && it.path == p })
            hpsTopics.add(0, HpsTopic(node.address(), p, channel, hosting = true, access = access))
    }

    fun hpsSubscribe(hostB58: String, path: String) {
        val host = runCatching { addressFromBase58(hostB58.trim()) }.getOrNull() ?: return
        val p = path.trim(); if (host.size != 32 || p.isEmpty()) return
        hpsSubscribeTo(host, p, channel = true)
    }

    private fun hpsSubscribeTo(host: ByteArray, path: String, channel: Boolean) {
        runCatching { node.hpsSubscribe(host, path) }
        if (hpsTopics.none { it.host.contentEquals(host) && it.path == path })
            hpsTopics.add(0, HpsTopic(host, path, channel = channel, hosting = false))
        pump()
    }

    fun hpsJoin(t: uniffi.hop_ffi.HpsTopicInfo) =
        hpsSubscribeTo(t.host, t.path, t.kind == HpsKind.CHANNEL)

    fun hpsPublish(topic: HpsTopic, text: String) {
        if (text.isEmpty()) return
        runCatching { node.hpsPublish(topic.path, text.toByteArray()) }
        appendThread(topic.id, HpsMsg(nextMsgId++, topic.path, node.address(), text)) // echo
        pump()
    }

    fun hpsInvite(topic: HpsTopic, to: ByteArray) {
        if (!topic.hosting || to.size != 32) return
        runCatching { node.hpsInvite(topic.path, to) }; pump()
    }

    fun hpsAcceptInvite(inv: uniffi.hop_ffi.HpsInvite) {
        runCatching { node.hpsAcceptInvite(inv.host, inv.path) }
        hpsInvites.removeAll { it.path == inv.path && it.host.contentEquals(inv.host) }
        if (hpsTopics.none { it.host.contentEquals(inv.host) && it.path == inv.path })
            hpsTopics.add(0, HpsTopic(inv.host, inv.path, inv.kind == HpsKind.CHANNEL, hosting = false))
        pump()
    }

    fun hpsDeclineInvite(inv: uniffi.hop_ffi.HpsInvite) {
        runCatching { node.hpsDeclineInvite(inv.host, inv.path) } // durable: won't reappear
        hpsInvites.removeAll { it.path == inv.path && it.host.contentEquals(inv.host) }
    }

    fun hpsPending(topic: HpsTopic): List<ByteArray> = runCatching { node.hpsPending(topic.path) }.getOrDefault(emptyList())
    fun hpsApprove(topic: HpsTopic, who: ByteArray) { runCatching { node.hpsApprove(topic.path, who) }; pump() }
    fun hpsDeny(topic: HpsTopic, who: ByteArray) { runCatching { node.hpsDeny(topic.path, who) } }
    fun hpsReach(topic: HpsTopic): Int = runCatching { node.hpsReach(topic.path).toInt() }.getOrDefault(0)
    fun hpsMembers(topic: HpsTopic): List<ByteArray> = runCatching { node.hpsMembers(topic.path) }.getOrDefault(emptyList())
    fun hpsRekey(topic: HpsTopic, remove: List<ByteArray> = emptyList()) { runCatching { node.hpsRekey(topic.path, "", remove) }; pump() }
    fun hpsBrowse(): List<uniffi.hop_ffi.HpsTopicInfo> = runCatching { node.browseDiscoverable() }.getOrDefault(emptyList())

    /// Rebuild the channel list from the node's persisted topics (hosted + subscribed) at startup.
    private fun loadHpsTopics() {
        runCatching { node.hpsMyTopics() }.getOrDefault(emptyList()).forEach { t ->
            val topic = HpsTopic(t.host, t.path, t.kind == HpsKind.CHANNEL, t.hosting, t.access)
            if (hpsTopics.none { it.id == topic.id }) hpsTopics.add(topic)
        }
    }

    fun hpsLeave(topic: HpsTopic) {
        runCatching { node.hpsLeave(topic.path) }
        hpsTopics.removeAll { it.id == topic.id }
        hpsThreads.remove(topic.id); hpsUnread.remove(topic.id)
        pump()
    }

    fun openTopic(id: String) { activeTopic = id; hpsUnread[id] = 0 }
    fun closeTopic() { activeTopic = null }

    /// Resolved display name for an address (its set name, or a short base58 prefix).
    fun displayName(addr: ByteArray): String = nameByAddr[addr.toList()] ?: shortHex(addr)
    /// Known peers as an invite-picker list (sorted by name).
    val contactList: List<Peer> get() = peers.sortedBy { it.name.lowercase() }

    private fun appendThread(id: String, m: HpsMsg) {
        val list = hpsThreads.getOrPut(id) { mutableStateListOf() }
        list.add(m)
        if (list.size > 500) list.removeAt(0)
        saveChannels()
    }

    // ---- channel-thread persistence (survives restart) ----------------------
    private val channelsFile get() = java.io.File(context.filesDir, "channels.json")
    private var channelSaveScheduled = false
    private fun saveChannels() {
        if (channelSaveScheduled) return
        channelSaveScheduled = true
        main.postDelayed({ channelSaveScheduled = false; writeChannels() }, 1000)
    }
    private fun writeChannels() {
        val root = org.json.JSONObject()
        for ((id, msgs) in hpsThreads) {
            val arr = org.json.JSONArray()
            for (m in msgs) {
                arr.put(org.json.JSONObject().apply {
                    put("path", m.path)
                    put("sender", android.util.Base64.encodeToString(m.sender, android.util.Base64.NO_WRAP))
                    put("text", m.text)
                })
            }
            root.put(id, arr)
        }
        runCatching { channelsFile.writeText(root.toString()) }
    }
    private fun loadHpsChannels() {
        val txt = runCatching { channelsFile.readText() }.getOrNull() ?: return
        val root = runCatching { org.json.JSONObject(txt) }.getOrNull() ?: return
        for (id in root.keys()) {
            val arr = root.optJSONArray(id) ?: continue
            val list = mutableStateListOf<HpsMsg>()
            for (i in 0 until arr.length()) {
                val o = arr.getJSONObject(i)
                list.add(HpsMsg(nextMsgId++, o.optString("path", ""),
                    android.util.Base64.decode(o.optString("sender", ""), android.util.Base64.NO_WRAP),
                    o.optString("text", "")))
            }
            hpsThreads[id] = list
        }
    }

    private fun drainHps() {
        for (m in node.takeHpsMessages()) {
            val topic = hpsTopics.firstOrNull { it.path == m.path }
            val id = topic?.id ?: m.path
            appendThread(id, HpsMsg(nextMsgId++, m.path, m.sender, String(m.body)))
            if (id != activeTopic) hpsUnread[id] = (hpsUnread[id] ?: 0) + 1
        }
        for (inv in node.takeHpsInvites()) {
            if (hpsInvites.none { it.path == inv.path && it.host.contentEquals(inv.host) })
                hpsInvites.add(inv)
        }
    }

    // ---- HNS & hops:// (DESIGN.md §30) -------------------------------------

    /// Open `hops://<domain>/<path>` (bare `<domain>` ok): resolve via HNS, then GET over the mesh.
    fun openHops(input: String) {
        val (domain, path) = parseHops(input)
        if (domain.isEmpty()) { hopsResults["?"] = "error: not a hops:// url"; return }
        hopsResults[domain] = "resolving…"
        when (val r = node.resolveHns(domain)) {
            is HnsLookupResult.Cached ->
                if (r.address.isEmpty()) hopsResults[domain] = "error: no hops endpoint for $domain"
                else fireHops(domain, path, r.address)
            is HnsLookupResult.Pending -> pendingHops[domain] = path
            is HnsLookupResult.NeedsResolver ->
                hopsResults[domain] = "error: offline — no internet or peers to resolve $domain"
        }
        pump()
    }

    private fun fireHops(domain: String, path: String, endpoint: ByteArray) {
        nameByAddr[endpoint.toList()] = domain // label the endpoint by its domain (endpoints list/traces)
        val id = runCatching {
            node.sendHopsRequest(endpoint, domain, "GET", path, ByteArray(0), 8u * 1024u * 1024u)
        }.getOrNull()
        if (id == null) { hopsResults[domain] = "error: could not send request to $domain"; return }
        hopsReqs[id.toList()] = domain
        hopsResults[domain] = "fetching…"
        pump()
    }

    // hops:// for the WebView (callback-style, per resource — DESIGN.md §30).
    private val hopsWebPending = HashMap<String, MutableList<Pair<String, (Int, String, ByteArray) -> Unit>>>()
    private val hopsWebReqs = HashMap<List<Byte>, (Int, String, ByteArray) -> Unit>()

    /// Fetch one hops:// resource for the WebView, calling back with (status, contentType, body).
    fun hopsFetch(url: String, cb: (Int, String, ByteArray) -> Unit) {
        main.post {
            val (domain, path) = parseHops(url)
            if (domain.isEmpty()) { cb(400, "text/plain; charset=utf-8", "bad url".toByteArray()); return@post }
            when (val r = node.resolveHns(domain)) {
                is HnsLookupResult.Cached ->
                    if (r.address.isEmpty()) cb(502, "text/plain; charset=utf-8", "no hops endpoint for $domain".toByteArray())
                    else fireHopsWeb(domain, path, r.address, cb)
                is HnsLookupResult.Pending -> hopsWebPending.getOrPut(domain) { mutableListOf() }.add(path to cb)
                is HnsLookupResult.NeedsResolver -> cb(503, "text/plain; charset=utf-8", "offline".toByteArray())
            }
            pump()
        }
    }

    private fun fireHopsWeb(domain: String, path: String, endpoint: ByteArray, cb: (Int, String, ByteArray) -> Unit) {
        nameByAddr[endpoint.toList()] = domain
        val id = runCatching {
            node.sendHopsRequest(endpoint, domain, "GET", path, ByteArray(0), 8u * 1024u * 1024u)
        }.getOrNull()
        if (id == null) { cb(502, "text/plain; charset=utf-8", "send failed".toByteArray()); return }
        hopsWebReqs[id.toList()] = cb
        pump()
    }

    private fun drainHns() {
        for (rec in node.takeHnsResults()) {
            // WebView fetches queued on this domain's resolution take priority.
            hopsWebPending.remove(rec.domain)?.let { queued ->
                for ((path, cb) in queued) {
                    if (rec.address.isEmpty()) cb(502, "text/plain; charset=utf-8", "no hops endpoint for ${rec.domain}".toByteArray())
                    else fireHopsWeb(rec.domain, path, rec.address, cb)
                }
            }
            val path = pendingHops.remove(rec.domain) ?: continue // the text-box fetch
            if (rec.address.isEmpty()) hopsResults[rec.domain] = "error: no hops endpoint for ${rec.domain}"
            else fireHops(rec.domain, path, rec.address)
        }
        for (resp in node.takeHttpResponses()) {
            val webCb = hopsWebReqs.remove(resp.forRequestId.toList())
            if (webCb != null) { webCb(resp.status.toInt(), resp.contentType, resp.body); continue }
            val domain = hopsReqs.remove(resp.forRequestId.toList()) ?: continue
            hopsResults[domain] = "${resp.status} · ${String(resp.body)}"
        }
        // Host DNS hook (§30): fetch each requested domain's full DNSSEC chain over DoH and hand
        // core the raw bodies — core validates to the root anchors and decides the address.
        for (domain in node.takeDnsLookups()) fetchDnssecChain(domain)
        // Refresh the cache debug view.
        hnsCache.clear()
        for (e in node.hnsCache()) hnsCache.add(HnsCacheRow(e.domain, e.address, e.ttlSecs))
    }

    /// Fetch a domain's DNSSEC chain over DNS-over-HTTPS (TXT _hopaddress + DNSKEY/DS per zone to
    /// root, all do=1), then feed the raw JSON bodies to core (§30). Concurrent GETs.
    private fun fetchDnssecChain(domain: String) {
        val queries = ArrayList<Pair<String, Int>>()
        queries.add("_hopaddress.$domain" to 16) // TXT
        var zone = domain
        while (true) {
            queries.add(zone to 48) // DNSKEY
            if (zone == ".") break
            queries.add(zone to 43) // DS
            zone = if (zone.contains(".")) zone.substringAfter(".") else "."
        }
        val bodies = java.util.Collections.synchronizedList(ArrayList<String>())
        val remaining = java.util.concurrent.atomic.AtomicInteger(queries.size)
        for ((name, qtype) in queries) {
            val req = Request.Builder().url("https://dns.google/resolve?name=$name&type=$qtype&do=1").build()
            dohClient.newCall(req).enqueue(object : okhttp3.Callback {
                override fun onFailure(call: okhttp3.Call, e: java.io.IOException) { done() }
                override fun onResponse(call: okhttp3.Call, response: Response) {
                    response.use { it.body?.string()?.let { b -> bodies.add(b) } }
                    done()
                }
                private fun done() {
                    if (remaining.decrementAndGet() == 0) main.post {
                        runCatching { node.provideDnsProof(domain, ArrayList(bodies)) }
                        pump()
                    }
                }
            })
        }
    }

    /// Parse a hops:// URL (or bare domain) into (domain, path). The endpoint validates host,
    /// so we pass the bare domain and just the path.
    private fun parseHops(input: String): Pair<String, String> {
        var s = input.trim().removePrefix("hops://").removePrefix("https://").removePrefix("http://")
        val slash = s.indexOf('/')
        val domain = (if (slash >= 0) s.substring(0, slash) else s).lowercase()
        val path = if (slash >= 0) s.substring(slash) else "/"
        return domain to path
    }

    // ---- cloud relay bearer (→ hop-relayd) ----------------------------------

    /// Connect to a `hop-relayd`. Accepts a `host:port` (raw TCP, path A) or a
    /// `ws://`/`wss://` URL (WebSocket, path B). The device dials → Noise initiator.
    /// Pin this device to a single relay by direct address (persisted), or pass null to clear the
    /// pin and fall back to the anycast default. Switches the one relay connection over now; the
    /// old relay's presence simply lapses (we never publish to two at once).
    fun setPinnedRelay(url: String?) {
        val pinned = url?.trim()?.takeIf { it.isNotEmpty() }
        pinnedRelay.value = pinned
        prefs.edit().apply { if (pinned != null) putString("pinnedRelay", pinned) else remove("pinnedRelay") }.apply()
        connectRelay(pinned ?: DEFAULT_RELAY)   // connectRelayWS/Tcp tears down the old link first
    }

    fun connectRelay(input: String) {
        val t = input.trim()
        relayUrl = t   // remembered so the tick loop auto-reconnects on drop (§28)
        if (t.startsWith("ws://") || t.startsWith("wss://")) connectRelayWS(t)
        else connectRelayTcp(t)
    }

    private fun connectRelayWS(url: String) {
        teardownRelay()
        relayStatus.value = "connecting…"
        val client = OkHttpClient.Builder().build()
        relayWS = client.newWebSocket(Request.Builder().url(url).build(), object : WebSocketListener() {
            override fun onOpen(ws: WebSocket, response: Response) { main.post {
                android.util.Log.i("HOPLOG", "relay connected: $url")
                relayStatus.value = "connected"; relayConnected = true
                node.connected(relayLinkId, true); pump()
            } }
            override fun onMessage(ws: WebSocket, bytes: ByteString) { main.post {
                node.received(relayLinkId, bytes.toByteArray()); pump()   // one frame = one packet
            } }
            override fun onClosing(ws: WebSocket, code: Int, reason: String) { main.post {
                android.util.Log.i("HOPLOG", "relay closing: $code $reason")
                relayStatus.value = "disconnected"; relayDown()
            } }
            override fun onFailure(ws: WebSocket, t: Throwable, response: Response?) { main.post {
                android.util.Log.w("HOPLOG", "relay failed: ${t.message}", t)
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

    // MARK: chat-history persistence (survives app restart) ----------------------

    private val messagesFile get() = java.io.File(context.filesDir, "messages.json")
    private var saveScheduled = false

    /// Coalesce rapid mutations into one disk write (~1/sec) so a burst of messages — or the
    /// per-tick pump() — doesn't re-encode the whole history each time.
    private fun saveMessages() {
        if (saveScheduled) return
        saveScheduled = true
        main.postDelayed({ saveScheduled = false; writeMessages() }, 1000)
    }

    private fun writeMessages() {
        val arr = org.json.JSONArray()
        for (m in messages) {
            val o = org.json.JSONObject()
            o.put("peer", m.peer); o.put("text", m.text); o.put("incoming", m.incoming)
            o.put("contentType", m.contentType)
            m.imageData?.let { o.put("imageData", android.util.Base64.encodeToString(it, android.util.Base64.NO_WRAP)) }
            if (m.images.isNotEmpty()) {
                val imgs = org.json.JSONArray()
                m.images.forEach { imgs.put(android.util.Base64.encodeToString(it, android.util.Base64.NO_WRAP)) }
                o.put("images", imgs)
            }
            o.put("hops", m.hops.toInt())
            m.latencyMs?.let { o.put("latencyMs", it.toLong()) }
            if (m.trace.isNotEmpty()) o.put("trace", org.json.JSONArray(m.trace))
            o.put("sentAt", m.sentAt)
            m.deliveredAt?.let { o.put("deliveredAt", it) }
            o.put("relayed", m.relayed.toLong())
            o.put("delivered", m.delivered); o.put("deliveryHops", m.deliveryHops.toInt())
            o.put("failed", m.failed)
            arr.put(o)
        }
        runCatching { messagesFile.writeText(arr.toString()) }
    }

    private fun loadMessages() {
        val txt = runCatching { messagesFile.readText() }.getOrNull() ?: return
        val arr = runCatching { org.json.JSONArray(txt) }.getOrNull() ?: return
        for (i in 0 until arr.length()) {
            val o = arr.getJSONObject(i)
            val incoming = o.getBoolean("incoming")
            val delivered = o.optBoolean("delivered", false)
            val imgs = o.optJSONArray("images")?.let { a ->
                (0 until a.length()).map { android.util.Base64.decode(a.getString(it), android.util.Base64.NO_WRAP) }
            } ?: emptyList()
            val trace = o.optJSONArray("trace")?.let { a -> (0 until a.length()).map { a.getString(it) } } ?: emptyList()
            messages.add(Message(
                localId = nextMsgId++, peer = o.getString("peer"), text = o.optString("text", ""),
                incoming = incoming, contentType = o.optString("contentType", "text/plain"),
                imageData = if (o.has("imageData")) android.util.Base64.decode(o.getString("imageData"), android.util.Base64.NO_WRAP) else null,
                images = imgs, hops = o.optInt("hops", 0).toUByte(),
                latencyMs = if (o.has("latencyMs")) o.getLong("latencyMs").toULong() else null,
                trace = trace, sentAt = o.optLong("sentAt", System.currentTimeMillis()),
                deliveredAt = if (o.has("deliveredAt")) o.getLong("deliveredAt") else null,
                relayed = o.optLong("relayed", 0).toUInt(), delivered = delivered,
                deliveryHops = o.optInt("deliveryHops", 0).toUByte(),
                // An outgoing message still in flight at quit can never ACK now — show "not sent".
                failed = o.optBoolean("failed", false) || (!incoming && !delivered),
            ))
        }
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
            .setNumber(unread.intValue)   // drives the launcher icon badge count
            .setBadgeIconType(NotificationCompat.BADGE_ICON_SMALL)
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
        // Map each directly-linked peer to its transport (BT vs the cloud relay). Android has no
        // Wi-Fi direct transport (MultipeerConnectivity is iOS-only), so a direct link is BLE.
        linkTransports.clear()
        val pls = runCatching { node.peerLinks() }.getOrDefault(emptyList())
        pls.forEach { pl ->
            linkTransports[pl.address.toList()] = if (pl.link == relayLinkId) "Relay" else "BT"
        }
        if (pls.isNotEmpty() && pls.size != lastPeerLinkCount) {
            lastPeerLinkCount = pls.size
            android.util.Log.i("HOPLOG", "peerLinks=${pls.size}: " +
                pls.joinToString { "${HopBearer.shortHex(it.address)}@${it.link}" })
        }

        // A live local radio link (BLE) IS a 1-hop path, so force hops=1 for those peers even if a
        // stale advert arrived via the relay at 2 hops. Keeps "direct" honest: direct iff hops<=1,
        // so a live-linked peer shows "1 hop · BT" (never "2 hops") and a no-link 2-hop peer is mesh.
        // Sort by the stable address so rows keep their position.
        val list = agg.values.map {
            val key = it.peer.address.toList()
            val t = linkTransports[key]
            val hops = if (t == "BT" || t == "Wi-Fi") 1u.toUByte() else it.minHops
            it.peer.copy(hops = hops)
        }.sortedBy { addressBase58(it.address) }
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
        android.util.Log.i("HOPLOG", "BLE peripheral: listening L2CAP psm=$psm")
        thread(name = "hop-accept") {
            while (true) {
                val socket = runCatching { ss.accept() }.getOrNull() ?: break
                android.util.Log.i("HOPLOG", "BLE peripheral: accepted L2CAP from ${socket.remoteDevice?.address}")
                addLink(socket, initiator = false)
                // Legacy connectable advertising STOPS once a central connects, so only one peer
                // could ever link. Re-arm it so every other iOS/Android device can still find us.
                main.post { startAdvertise() }
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

        startAdvertise()
        status.value = "advertising (psm $psm)"
    }

    /// (Re)start connectable advertising. Called at startup and re-armed after each accepted
    /// connection, because legacy advertising stops on connect (so without this only one peer
    /// could ever link to us).
    private fun startAdvertise() {
        val adv = adapter.bluetoothLeAdvertiser ?: return
        runCatching { adv.stopAdvertising(advertiseCallback) } // no-op if not advertising
        adv.startAdvertising(
            AdvertiseSettings.Builder()
                .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
                .setConnectable(true)
                .build(),
            AdvertiseData.Builder().addServiceUuid(ParcelUuid(SERVICE_UUID)).build(),
            advertiseCallback,
        )
    }

    private val gattServerCallback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            android.util.Log.i("HOPLOG", "BLE peripheral GATT: ${device.address} status=$status newState=$newState")
        }
        override fun onCharacteristicReadRequest(
            device: BluetoothDevice, requestId: Int, offset: Int,
            characteristic: BluetoothGattCharacteristic,
        ) {
            // PSM as 2 bytes big-endian — must match iOS, whose CBL2CAPPSM is a UInt16. (A
            // 4-byte form here makes iOS read PSM 0 and Android read out of bounds → no
            // cross-platform BLE link.)
            val value = if (characteristic.uuid == PSM_CHAR_UUID) {
                android.util.Log.i("HOPLOG", "BLE peripheral: ${device.address} read our PSM=$psm")
                byteArrayOf((psm ushr 8).toByte(), psm.toByte())
            } else ByteArray(0)
            gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
        }
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
            android.util.Log.i("HOPLOG", "BLE advertising started")
        }
        override fun onStartFailure(errorCode: Int) {
            android.util.Log.w("HOPLOG", "BLE advertising FAILED: code=$errorCode")
        }
    }

    // ---- central: scan + open L2CAP -----------------------------------------

    private fun startCentral() {
        val scanner = adapter.bluetoothLeScanner ?: return
        val filter = ScanFilter.Builder().setServiceUuid(ParcelUuid(SERVICE_UUID)).build()
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        scanner.startScan(listOf(filter), settings, scanCallback)
        android.util.Log.i("HOPLOG", "BLE central: scanning for Hop peers")
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val device = result.device
            if (!connecting.add(device.address)) return
            android.util.Log.i("HOPLOG", "BLE central: found ${device.address}, connecting…")
            // connectGatt MUST run on the main thread — calling it from this binder callback
            // thread is a common cause of the status-133 connect failure on many devices.
            main.post { device.connectGatt(context, false, gattCallback, BluetoothDevice.TRANSPORT_LE) }
        }
        override fun onScanFailed(errorCode: Int) {
            android.util.Log.w("HOPLOG", "BLE scan FAILED: code=$errorCode")
        }
    }

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, statusCode: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED && statusCode == BluetoothGatt.GATT_SUCCESS) {
                gatt.discoverServices()
            } else {
                // Failed or dropped. MUST close to free the GATT client — Android caps these,
                // and leaked failed connects make every later connect time out. Drop from the
                // in-flight set so a later scan can retry. (A live link keeps its GATT open, so
                // no disconnect fires for it.)
                android.util.Log.i("HOPLOG", "BLE central: ${gatt.device.address} disconnected status=$statusCode state=$newState")
                runCatching { gatt.close() }
                connecting.remove(gatt.device.address)
            }
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
            if (v.size < 2) return
            // 2 bytes big-endian (matches iOS's UInt16 PSM).
            val psm = (v[0].toInt() and 0xff shl 8) or (v[1].toInt() and 0xff)
            val device = gatt.device
            thread(name = "hop-l2cap-connect") {
                val socket = runCatching {
                    device.createInsecureL2capChannel(psm).apply { connect() }
                }.getOrNull()
                if (socket == null) {
                    runCatching { gatt.close() }      // free the GATT client
                    connecting.remove(device.address) // allow a retry on the next scan
                    return@thread
                }
                addLink(socket, initiator = true)     // GATT stays open to hold the link
            }
        }
    }

    companion object {
        val SERVICE_UUID: UUID = UUID.fromString("F0900000-0000-4000-8000-000000000000")
        val PSM_CHAR_UUID: UUID = UUID.fromString("F0900001-0000-4000-8000-000000000000")
        const val CHANNEL_ID = "hop.messages"
        const val PRESENCE_SERVICE = "presence"
        const val PRESENCE_TTL_MS: UInt = 600_000u
        const val DEFAULT_RELAY = "wss://relay.hopme.sh/"
        /// Shared app secret for Hop Debug — all our demo devices use it so they interoperate.
        /// A different app (different secret) can't see or join these channels (DESIGN.md §32).
        val APP_SECRET = ByteArray(32) { 0x48 } // "H" ×32 — dev build only (matches iOS)

        @Volatile private var inst: HopBearer? = null

        /// One shared instance, owned by the foreground service and observed by the UI.
        fun shared(context: Context): HopBearer =
            inst ?: synchronized(this) {
                inst ?: HopBearer(context.applicationContext).also { inst = it }
            }

        fun nowMs(): ULong = System.currentTimeMillis().toULong()

        /// Encode `(contentType, bytes)` parts into the multipart wire format (shared with iOS).
        fun encodeMultipart(parts: List<Pair<String, ByteArray>>): ByteArray {
            val out = java.io.ByteArrayOutputStream()
            fun u32(v: Int) { out.write(v ushr 24); out.write(v ushr 16); out.write(v ushr 8); out.write(v) }
            fun u16(v: Int) { out.write(v ushr 8); out.write(v) }
            u32(parts.size)
            for ((ct, body) in parts) {
                val ctd = ct.toByteArray()
                u16(ctd.size); out.write(ctd)
                u32(body.size); out.write(body)
            }
            return out.toByteArray()
        }

        /// Decode the multipart wire format into `(contentType, bytes)` parts.
        fun decodeMultipart(data: ByteArray): List<Pair<String, ByteArray>> {
            val parts = mutableListOf<Pair<String, ByteArray>>()
            var i = 0
            fun u(n: Int): Int? {
                if (i + n > data.size) return null
                var v = 0; repeat(n) { v = (v shl 8) or (data[i].toInt() and 0xff); i++ }; return v
            }
            val count = u(4) ?: return parts
            repeat(count) {
                val cl = u(2) ?: return parts
                if (i + cl > data.size) return parts
                val ct = String(data, i, cl); i += cl
                val bl = u(4) ?: return parts
                if (i + bl > data.size) return parts
                parts.add(ct to data.copyOfRange(i, i + bl)); i += bl
            }
            return parts
        }

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
