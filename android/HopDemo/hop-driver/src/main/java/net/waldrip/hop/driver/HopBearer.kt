package net.waldrip.hop.driver

import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
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
import uniffi.hop.HopNode
import uniffi.hop.HnsLookupResult
import uniffi.hop.HpsKind
import uniffi.hop.TraceHopInfo
import uniffi.hop.addressBase58
import uniffi.hop.addressFromBase58
import uniffi.hop.decodeIdentity
import uniffi.hop.serviceIdentify

/**
 * Foreground Android BLE bearer for Hop: each device acts as both peripheral
 * (advertise the shared Hop service UUID + accept L2CAP) and central (scan + open
 * L2CAP), carrying the node's byte packets over L2CAP CoC. Mirrors the iOS bearer;
 * does no protocol work — just shuttles bytes via connected/received/drainOutgoing.
 */
@SuppressLint("MissingPermission")
class HopBearer private constructor(private val context: Context, private val config: HopConfig) {

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
        val deliveryMs: ULong? = null, // forward-path (A→B) latency the recipient reported, ms
        val failed: Boolean = false,   // gave up (e.g. the queue was cleared before it sent)
    )

    // Identity derived from the device (stable, storage-independent — §4); the db path
    // persists messages across restarts. Both come from the host-supplied HopConfig.
    val node: HopNode = HopNode.`open`(
        config.dbPath,
        config.identitySecret,
        config.appSecret,
    )
    val peers = mutableStateListOf<Peer>()
    /// Persistent address book: everyone we've seen, messaged, or been messaged by, keyed by address.
    /// `seen` is the subset NOT currently reachable — so past conversations stay reachable even when
    /// the peer is offline / out of range / after a restart (mirrors iOS).
    private val contacts = HashMap<List<Byte>, Peer>()
    val seen = mutableStateListOf<Peer>()
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
    val hpsInvites = mutableStateListOf<uniffi.hop.HpsInvite>()         // invites received
    @Volatile var activeTopic: String? = null                              // topic on screen

    // Diagnostics (Status tab) — parity with iOS: service-call log + relay queue.
    val serviceLog = mutableStateListOf<String>()
    val queue = mutableStateListOf<QueueRow>()
    data class QueueRow(val own: Boolean, val to: String, val priority: UByte, val hops: UByte)
    private val identifyAsked = HashSet<List<Byte>>()   // addresses we've sent hop.identify to
    private val identifyReqs = HashSet<List<Byte>>()    // outstanding identify request ids
    data class HpsTopic(
        val host: ByteArray, val path: String, val channel: Boolean, val hosting: Boolean,
        val access: uniffi.hop.HpsAccess = uniffi.hop.HpsAccess.OPEN,
    ) {
        val id: String get() = addressBase58(host) + "/" + path
        val writable: Boolean get() = channel || hosting
    }
    data class HpsMsg(val id: Long, val path: String, val sender: ByteArray, val text: String)
    var myAddress = mutableStateOf("")
    var myName = mutableStateOf("")
    // Core also READS our name/address/private-mode (publishPresence, LAN discovery), so those live
    // in @Volatile backing fields the core thread reads; the mutableStateOf above is the UI mirror,
    // written via onUi. (Keeps "Compose state mutates only on main" without racing core's reads.)
    @Volatile private var myAddressVal = ""
    @Volatile private var myNameVal = ""
    @Volatile private var privateModeVal = false
    /// Privacy: when on, we stop broadcasting our presence advert (name + address). We stay fully
    /// relay-capable and reachable by anyone who already has our address (scanned QR / manual add).
    val privateMode = mutableStateOf(false)
    var status = mutableStateOf("starting…")
    var relayStatus = mutableStateOf("not connected")
    private val prefs get() = context.getSharedPreferences("hop", android.content.Context.MODE_PRIVATE)
    /// A relay the user pinned by direct address (persisted). A device only ever talks to ONE
    /// relay — routing is anycast — so pinning overrides the anycast default for testing a
    /// specific relay, rather than publishing presence to several at once.
    val pinnedRelay = mutableStateOf<String?>(null)
    private var nextMsgId = 0L
    @Volatile private var appActive = true
    private val appName: String =
        context.applicationInfo.loadLabel(context.packageManager).toString()

    // Threading model (DESIGN: Stage C). Every node.* call and all bearer plumbing run on ONE serial
    // background thread (hop.core), so the main thread never does node/SQLite/crypto work — under
    // multi-peer BLE load that path ANR'd ("Skipped N frames"). The node is internally Mutex-guarded
    // (thread-safe), so the rare synchronous UI getters (node.address(), hpsReach/Members/…) can still
    // read it directly from main. Compose snapshot state is UI state: it is WRITTEN ONLY on the main
    // thread via onUi { } — core does the node work, then marshals the visible result to main. The
    // heavy SQLite-backed refresh stays coalesced (~4 Hz, scheduleRefresh); never refresh per-frame.
    private val coreThread = HandlerThread("hop.core").apply { start() }
    private val core = Handler(coreThread.looper)
    private val main = Handler(Looper.getMainLooper())
    /// Marshal a Compose-state update to the main thread. UI (snapshot) state mutates ONLY here.
    private fun onUi(block: () -> Unit) { main.post(block) }
    private val adapter: BluetoothAdapter by lazy {
        (context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
    }
    private val links = HashMap<ULong, HopLink>()
    private var nextLinkId: ULong = 1u
    private var lastPeerLinkCount = -1
    @Volatile private var psm: Int = -1                 // written on core, read on GATT binder callbacks
    private var serverSocket: BluetoothServerSocket? = null
    @Volatile private var gattServer: BluetoothGattServer? = null  // read on GATT binder callbacks
    // GATT-data fallback bearer (cross-platform, when L2CAP can't open — esp. Apple→Android).
    private var peripheralDataChar: BluetoothGattCharacteristic? = null
    private val gattLinks = HashMap<ULong, GattDataLink>()        // all GATT-data links (central + peripheral)
    private val gattLinkDevice = HashMap<ULong, BluetoothDevice>() // peripheral side: link → the central device
    // central side: link → its gatt client. Scanned on GATT binder callback threads (to find a link
    // by its BluetoothGatt) as well as written on core, so concurrent-safe.
    private val gattLinkGatt = java.util.concurrent.ConcurrentHashMap<ULong, BluetoothGatt>()
    // Touched from GATT binder callback threads as well as core, so concurrent-safe.
    private val deviceGattLink = java.util.concurrent.ConcurrentHashMap<String, ULong>() // peripheral: central addr → link id
    private val gattMtu = java.util.concurrent.ConcurrentHashMap<String, Int>()          // device addr → negotiated ATT MTU (default 23)
    private var nextGattLinkId = GattDataLink.GATT_LINK_BASE
    private val connecting = HashSet<String>()       // BLE addrs we have a link to OR are dialing
    // Push-to-peripheral central (DESIGN.md §11): to deliver we connect as a central to a peer's
    // peripheral and write — but GENTLY. Cap concurrent outbound dials, time them out, and back off
    // peers that fail, so the central never floods/saturates the radio and starves OUR peripheral
    // (the inbox other devices push into). All mutated on the hop.core thread.
    private val dialing = HashSet<String>()                     // outbound L2CAP dials in flight (addrs)
    private val dialBackoffUntil = HashMap<String, Long>()      // addr → earliest next attempt (wall ms)
    private val dialBackoffStep = HashMap<String, Long>()       // addr → current backoff interval
    // DIAG (handshake-flow trace): cumulative bytes shuttled per BLE link, so the 1 Hz tick can show
    // whether a link that came UP is actually exchanging the Noise handshake (rx>0 = peer is talking).
    private val linkTx = HashMap<ULong, Long>()
    private val linkRx = HashMap<ULong, Long>()
    private val prevRx = HashMap<ULong, Long>()   // rx snapshot per dedup cycle → "is this link actively receiving?"
    // DIAG: per-link outgoing LinkPacket-type histogram [handshake, data, datafrag, other] by
    // postcard discriminant (bytes[0]). Tells us if a flood is re-handshakes vs data records.
    private val pktHisto = HashMap<ULong, LongArray>()
    // Read from the UI thread (displayName) and written on core (refresh/pump), so concurrent-safe.
    private val nameByAddr = java.util.concurrent.ConcurrentHashMap<List<Byte>, String>()

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

    // LAN bearer (mDNS/NSD + TCP) and Wi-Fi Direct bearer — the cross-platform high-bandwidth Wi-Fi
    // paths. Both reuse LanLink and a single TCP server bound on a fixed port: NSD links devices on a
    // shared Wi-Fi network; Wi-Fi Direct links Android↔Android peer-to-peer with no router. Distinct
    // link-id range (40_000+) so refresh() tags them "Wi-Fi" and treats them as direct (1 hop).
    private val lanLinks = HashMap<ULong, LanLink>()
    private var lanNextLinkId: ULong = 40_000u          // LAN (mDNS, shared network) link ids
    private var wifiDirectNextLinkId: ULong = 50_000u   // Wi-Fi Direct (P2P, no network) link ids
    private val lanDialed = HashMap<String, ULong>()    // peer base58 → our outbound link id (dedup)
    private var lanServer: java.net.ServerSocket? = null
    private var nsdManager: android.net.nsd.NsdManager? = null
    private var nsdRegListener: android.net.nsd.NsdManager.RegistrationListener? = null
    private var nsdDiscListener: android.net.nsd.NsdManager.DiscoveryListener? = null
    @Volatile private var resolvingNsd = false          // NsdManager.resolveService is one-at-a-time
    private var wifiDirect: WifiDirectBearer? = null

    // ---- shared cross-platform transport layer (ble-lab bearer-core/-ble/-lan) ----------------
    // Default-on (config.useSharedBearers): pure-L2CAP BLE + LAN multiplexed by ONE BearerManager,
    // surfaced through bearerSink into the SAME node seam the legacy transports use. The manager's
    // global link-id space starts HIGH (1_000_000) so its ids never collide with the ULong nextLinkId
    // (1+) / relay (20k) / LAN (40k) / Wi-Fi Direct (50k) ranges the legacy transports still mint.
    private val bearerMgr = sh.hop.BearerManager(baseLinkId = 1_000_000L)
    // One transport id shared by both bearers (the BLE/LAN HELLO id + greater-id dedup tiebreaker);
    // distinct from the Hop node address — Noise is still negotiated over the bearer's DATA frames.
    private val bearerId = sh.hop.randomNodeId()
    // Link ids currently owned by the BearerManager, so pump() routes their packets to it. CORE-CONFINED:
    // added/removed and read ONLY inside core.post (pump() also runs on core), so it needs no lock.
    private val bearerLinks = HashSet<Long>()
    // Adapts the shared BearerManager to the existing node seam. Every link from either bearer surfaces
    // here and drives node.connected/received/disconnected exactly like the legacy paths (linkId
    // mismatch: the bearer libs use Long, the node uses ULong — convert at this boundary).
    private val bearerSink = object : sh.hop.LinkSink {
        override fun linkUp(link: Long, role: sh.hop.HopRole, peerId: ByteArray) {
            core.post {
                bearerLinks.add(link)
                node.connected(link.toULong(), role == sh.hop.HopRole.DIALER)
                pump()   // ship the dialer's queued Noise m1 immediately (mirrors legacy addLink / Apple linkUp)
            }
        }
        override fun linkBytes(link: Long, bytes: ByteArray) {
            core.post { node.received(link.toULong(), bytes); pump() }
        }
        override fun linkDown(link: Long) {
            core.post {
                bearerLinks.remove(link)
                node.disconnected(link.toULong())
                scheduleRefresh()   // mirrors legacy onClose / Apple linkDown
            }
        }
    }

    @Volatile var appInForeground = false
    private var started = false

    fun start(name: String = config.deviceName) = core.post {
        if (started) return@post
        started = true
        ensureNotificationChannel()
        loadMessages()      // restore chat history from the previous run
        loadContacts()      // restore the address book so past conversations are reachable when offline
        loadHpsChannels()   // restore channel (hps) message threads
        loadHpsTopics()     // restore hosted/subscribed channels (the node persists them)
        myNameVal = name; onUi { myName.value = name }
        val addr58 = addressBase58(node.address())
        myAddressVal = addr58; onUi { myAddress.value = addr58 }
        android.util.Log.i("HOPLOG", "HOPAUTO self=$addr58 name=${config.deviceName}")   // test harness reads this for targeting
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
        if (config.useSharedBearers) {
            // Shared transport layer (HopBearers): pure-L2CAP BLE + LAN multiplexed by ONE
            // BearerManager. The BleBearer owns the peripheral+central roles and the LanBearer owns
            // NSD/TCP, so the legacy in-driver BLE/LAN/Wi-Fi-Direct paths below are gated OFF (they'd
            // otherwise double-run the radio). Seed the background flag (foreground-service default
            // false), point the manager at our node adapter, register BLE + LAN, and start. NOTE:
            // BleBearer is pure-L2CAP by design — the legacy GattDataLink fallback is simply not
            // started on this path (the proven clean-room transport).
            sh.hop.appInBackground = !appActive
            bearerMgr.sink = bearerSink
            bearerMgr.register(net.waldrip.hop.bearers.ble.BleBearer(context, bearerId))
            bearerMgr.register(net.waldrip.hop.bearers.lan.LanBearer(context, bearerId))
            // Wi-Fi Direct (Android-only): peer-to-peer Wi-Fi when there's no shared router. Self-contained
            // standalone bearer (its own P2P group + TCP server/socket), same nodeId + global LinkId space.
            bearerMgr.register(net.waldrip.hop.bearers.wifidirect.WifiDirectBearer(context, bearerId))
            // Cloud relay (WebSocket) as a shared bearer — ONE outbound link to the backbone, registered
            // only when relays are enabled and a URL exists. The legacy in-driver relay dial is gated OFF
            // below so the two never double-connect. (P2P test mode sets relaysEnabled=false, so this
            // stays unregistered — the relay is COMPILE-VERIFIED here, not runtime-proven.)
            if (config.relaysEnabled) {
                val relay = prefs.getString("pinnedRelay", null) ?: config.relayUrl
                if (relay.isNotEmpty())
                    bearerMgr.register(net.waldrip.hop.bearers.relay.RelayBearer(relay))
            }
            bearerMgr.start()
            android.util.Log.i("HOPLOG", "shared bearers started (BLE+LAN+Wi-Fi-Direct${if (config.relaysEnabled) "+Relay" else ""}) id=${bearerId.take(4).joinToString("") { "%02x".format(it) }}")
        } else {
            startPeripheral()
            // Dual-role: always a peripheral (others connect TO us to push — the receive mailbox),
            // plus a GENTLE, bursty central so we can push too (and reach Android peers). The central
            // scans in short windows with long idle gaps so the radio stays mostly in peripheral mode
            // — a continuous scan saturated the radio and starved discovery (iOS couldn't connect).
            startCentral()
            // Auto-heal a wedged BLE stack: when the user (or a watchdog) toggles Bluetooth off→on, the
            // L2CAP listener / GATT server / advertising sets all become invalid and the app would
            // otherwise sit deaf until a full restart (the recurring "links cycle but no data flows, had
            // to force-stop" failure). Re-initialize the peripheral + central when the adapter returns.
            registerBtStateReceiver()
            // Cross-platform Wi-Fi paths: NSD/TCP on a shared network, Wi-Fi Direct peer-to-peer when
            // there's no router. Both feed the node like any other transport.
            startLan()
            startWifiDirect()
        }
        // Declare internet reachability so the node resolves HNS itself by servicing
        // takeDnsLookups() (DESIGN.md §30). Track the default network so it stays accurate.
        val cm = context.getSystemService(android.net.ConnectivityManager::class.java)
        runCatching {
            val net = cm?.activeNetwork
            val caps = net?.let { cm.getNetworkCapabilities(it) }
            node.setInternet(caps?.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET) == true)
            cm?.registerDefaultNetworkCallback(object : android.net.ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: android.net.Network) { core.post { node.setInternet(true); pump() } }
                override fun onLost(network: android.net.Network) { core.post { node.setInternet(false) } }
            })
        }
        // Check in to the backbone (DESIGN.md §28): dial the anycast relay so we pull any
        // queued mail and stay reachable across the internet. The foreground service keeps
        // this alive; the tick loop below reconnects it if it ever drops.
        val pinned = prefs.getString("pinnedRelay", null)
        val priv = prefs.getBoolean("privateMode", false)
        privateModeVal = priv
        onUi { pinnedRelay.value = pinned; privateMode.value = priv }
        // LEGACY relay only: with the shared bearers ON, the shared RelayBearer owns the cloud relay.
        if (!config.useSharedBearers) {
            if (config.relaysEnabled) connectRelay(pinned ?: config.relayUrl)
            else onUi { relayStatus.value = "disabled" }   // pure-P2P mode (HopConfig.relaysEnabled=false)
        }
        var ticks = 0
        core.postDelayed(object : Runnable {
            override fun run() {
                node.tick(nowMs())
                if (++ticks % 20 == 0) publishPresence()
                // Re-publish our prekey periodically so a neighbour whose cached copy lapsed
                // (or who arrived later) can always open a forward-secret session to us (§25).
                if (ticks % 120 == 0) runCatching { node.publishPrekey() }
                // Self-heal advertising: startAdvertise() is idempotent (no-op while the set is live),
                // so this only restarts it if it actually stopped (advSet cleared in onAdvertisingSetStopped
                // — e.g. OEM doze or a wedged stack). No reset of a healthy advert, so the name stays put.
                // Legacy-path self-heal only: with the shared bearers ON, BleBearer owns advertising.
                if (!config.useSharedBearers && ticks % 30 == 0) runCatching { startAdvertise() }
                if (!config.useSharedBearers && ticks % 30 == 0) runCatching { startBeacon() }   // self-heal the iBeacon too
                if (ticks % 15 == 0) android.util.Log.i("HOPLOG", "HOPAUTO self=$myAddressVal name=${config.deviceName}")  // periodic, so the harness always finds it
                // Keep the relay connected: a foreground service runs continuously, so a
                // reconnect here means real-time background delivery, not just on next launch.
                // Throttled so a flapping link doesn't hammer the dial (§28).
                // LEGACY relay only: the shared RelayBearer reconnects itself with its own backoff.
                if (!config.useSharedBearers && config.relaysEnabled && !relayConnected && relayStatus.value != "connecting…") {
                    val now = nowMs()
                    if (now - lastRelayDialMs > 4000u) {
                        lastRelayDialMs = now
                        relayUrl?.let { connectRelay(it) }
                    }
                }
                maintainGattLinks()
                pump()
                dedupBleLinks()
                // DIAG: per-BLE-link byte flow. If a link is UP but stuck (no peerLinks), this shows
                // whether the Noise handshake is exchanging: rx=0 → peer never sent m1 (its send side);
                // tx>0,rx=0 → we sent but peer silent; tx>0,rx>0 → bytes flow but handshake won't finish.
                val pls = runCatching { node.peerLinks() }.getOrDefault(emptyList())
                val distinctPeers = pls.map { it.address.toList() }.distinct().size
                if (links.isNotEmpty()) android.util.Log.i("HOPLOG",
                    "NODESTATE upLinks=${pls.size} bleLinks=${links.size} peers=$distinctPeers pend=${runCatching { node.pendingCount() }.getOrDefault(0u)} " +
                    pls.joinToString(" ") { p -> "id${p.link}=${p.address.take(3).joinToString(""){ b -> "%02x".format(b) }}" +
                        "[sec=${runCatching { node.isSecured(p.address) }.getOrDefault(false)},rt=${runCatching { node.knowsRoute(p.address) }.getOrDefault(false)}]" })
                for ((lid, _) in links) {
                    val h = pktHisto[lid] ?: LongArray(4)
                    android.util.Log.i("HOPLOG", "LINKFLOW id=$lid tx=${linkTx[lid] ?: 0L} rx=${linkRx[lid] ?: 0L} " +
                        "txpkts[hs=${h[0]} data=${h[1]} frag=${h[2]} other=${h[3]}]")
                }
                core.postDelayed(this, 1000)
            }
        }, 1000)
    }

    /// One-pipe-per-pair. An iOS rotating-MAC dialer can open SEVERAL L2CAP channels to us, leaving
    /// multiple Up links to the SAME identified peer. The node then gossips/offers across ALL of them
    /// and traffic AMPLIFIES into a flood that saturates the few-KB/s BLE pipe (resource exhaustion) —
    /// real messages then crawl through over minutes/hours. node.peerLinks() maps each Up link to its
    /// peer address, so once a duplicate's handshake completes we detect it and close the extra,
    /// keeping exactly ONE BLE link per peer. Runs on hop.core (the 1 Hz tick). Only inspects BLE
    /// links (the `links` map) — a legit BLE+LAN dual-transport to one peer is left alone.
    private fun dedupBleLinks() {
        val byPeer = HashMap<List<Byte>, MutableList<ULong>>()
        runCatching { node.peerLinks() }.getOrDefault(emptyList()).forEach { pl ->
            if (links.containsKey(pl.link)) byPeer.getOrPut(pl.address.toList()) { mutableListOf() }.add(pl.link)
        }
        for ((_, lids) in byPeer) {
            if (lids.size <= 1) continue
            // Keep the link that is ACTUALLY CARRYING TRAFFIC (rx grew since the last cycle ⇒ both
            // ends agree it's alive); close the stale duplicates. Tie-break to the newest id when
            // none (or several) are active. This CONVERGES — both peers keep the bidirectionally-live
            // pipe — unlike keep-oldest (wedged on a dead link → endless re-dial churn) or keep-newest
            // (ping-ponged when the peer was still using the older link).
            val keep = lids.maxByOrNull { lid ->
                val active = (linkRx[lid] ?: 0L) > (prevRx[lid] ?: 0L)
                (if (active) 1_000_000_000_000_000L else 0L) + lid.toLong()
            } ?: continue
            lids.filter { it != keep }.forEach { dup ->
                android.util.Log.i("HOPLOG", "DEDUP closing stale duplicate BLE link id=$dup keep=$keep (same peer, ${lids.size} links)")
                runCatching { links[dup]?.close() }
            }
        }
        // Snapshot rx for the next cycle's activity check.
        runCatching { node.peerLinks() }.getOrDefault(emptyList()).forEach { prevRx[it.link] = linkRx[it.link] ?: 0L }
    }

    /// Keepalive + reaping for GATT-data links (the bearer drives these; GattDataLink has no timer
    /// of its own). Reap a half-open link (subscribed but never sent a frame — the dead-link case)
    /// or one silent past the liveness window; otherwise send an empty keepalive frame.
    private fun maintainGattLinks() {
        if (gattLinks.isEmpty()) return
        for (id in gattLinks.keys.toList()) {
            val link = gattLinks[id] ?: continue
            if (link.isHalfOpen() || link.idleMs() > GATT_LIVENESS_MS) {
                android.util.Log.i("HOPLOG", "GATT-data link reaped id=$id")
                closeGattLink(id)
            } else {
                link.send(ByteArray(0))   // keepalive
            }
        }
    }

    /// Re-publish our presence advert so it stays within TTL and renames propagate.
    /// `summary` carries app-level metadata: "state|platform|app".
    private fun publishPresence() {
        if (privateModeVal) return   // private: don't broadcast our name/address
        val meta = "${if (appActive) "fg" else "bg"}|android|$appName"
        runCatching {
            node.publishService(PRESENCE_SERVICE, myNameVal, meta, emptyList(), PRESENCE_TTL_MS)
        }
    }

    /// Toggle private mode (persisted). On → supersede our live presence with a near-instantly-
    /// expiring one so peers drop our name now. Off → start broadcasting again.
    fun setPrivateMode(on: Boolean) {
        privateModeVal = on          // core reads this in publishPresence
        privateMode.value = on       // UI mirror (caller is main)
        prefs.edit().putBoolean("privateMode", on).apply()
        core.post {
            if (on) {
                val meta = "${if (appActive) "fg" else "bg"}|android|$appName"
                runCatching { node.publishService(PRESENCE_SERVICE, myNameVal, meta, emptyList(), 1000u) }
                pump()
            } else publishPresence()
        }
    }

    /// The host activity calls this on resume/pause; we re-publish presence so peers
    /// see our current foreground/background state.
    fun setForeground(fg: Boolean) {
        appActive = fg
        appInForeground = fg
        sh.hop.appInBackground = !fg   // shared bearers: relax liveness deadline when backgrounded
        if (fg) {   // the user is looking at the app → clear the unread badge + notifications
            unread.intValue = 0
            runCatching { NotificationManagerCompat.from(context).cancelAll() }
        }
        core.post { publishPresence(); pump() }
    }

    /** Stable conversation key for a peer — its base58 ADDRESS, never its display name. Two distinct
     *  peers that happen to share a name (e.g. two "Pixel 7"s) must not collapse into one thread. */
    fun keyFor(p: Peer): String = addressBase58(p.address)

    /** Test/automation hook: send [text] to a base58 ADDRESS, building a minimal Peer (no UI selection
     *  needed). Backs the hopdemo://send deep link so a harness can drive sends without UI taps. */
    fun sendTo(addrBase58: String, text: String) {
        val addr = runCatching { addressFromBase58(addrBase58.trim()) }.getOrNull() ?: return
        send(text, Peer(addr, contacts[addr.toList()]?.name ?: "", 0u, active = false))
    }

    fun send(text: String, to: Peer) = core.post {
        rememberContact(to)   // messaging someone adds them to your address book
        val id = runCatching {
            node.sendMessage(to.address, "text/plain", text.toByteArray(), true)
        }.getOrNull()
        val msg = Message(localId = nextMsgId++, peer = addressBase58(to.address), text = text, incoming = false, bundleId = id)
        onUi { messages.add(msg) }
        pump()
    }

    /// Send an image — large bodies are transparently carrier-chunked + reassembled by core
    /// (DESIGN.md §20), same path as a text message but a binary content type.
    fun sendImage(data: ByteArray, to: Peer) = core.post {
        rememberContact(to)
        val id = runCatching {
            node.sendMessage(to.address, "image/jpeg", data, true)
        }.getOrNull()
        val msg = Message(localId = nextMsgId++, peer = addressBase58(to.address), text = "", incoming = false,
            bundleId = id, contentType = "image/jpeg", imageData = data)
        onUi { messages.add(msg) }
        pump()
    }

    /// Send text and/or one-or-more images as ONE message (multipart/mixed) — a single sealed
    /// payload (DESIGN.md §20/§32). Wire format shared with iOS:
    /// `[u32 partCount][ per part: u16 ctLen, ct, u32 bodyLen, body ]`.
    fun sendMultipart(text: String, images: List<ByteArray>, to: Peer) = core.post {
        val t = text.trim()
        val parts = ArrayList<Pair<String, ByteArray>>()
        if (t.isNotEmpty()) parts.add("text/plain" to t.toByteArray())
        for (img in images) parts.add("image/jpeg" to img)
        if (parts.isEmpty()) return@post
        rememberContact(to)
        val id = runCatching {
            node.sendMessage(to.address, "multipart/mixed", encodeMultipart(parts), true)
        }.getOrNull()
        val msg = Message(localId = nextMsgId++, peer = addressBase58(to.address), text = t, incoming = false,
            bundleId = id, contentType = "multipart/mixed", images = images)
        onUi { messages.add(msg) }
        pump()
    }

    /// Re-send a failed ("Not sent") message in place. Recovery for a message that gave up
    /// (queue cleared, or still unsent at a restart). `to` supplies the address (Message stores
    /// only the peer name).
    fun retry(m: Message, to: Peer) = core.post {
        if (m.incoming) return@post
        val ctBody: Pair<String, ByteArray> = when {
            m.contentType.startsWith("image/") -> {
                val d = m.imageData ?: return@post
                "image/jpeg" to d
            }
            m.contentType == "multipart/mixed" -> {
                val parts = ArrayList<Pair<String, ByteArray>>()
                if (m.text.isNotEmpty()) parts.add("text/plain" to m.text.toByteArray())
                val imgs = if (m.imageData != null) listOf(m.imageData) else m.images
                for (img in imgs) parts.add("image/jpeg" to img)
                if (parts.isEmpty()) return@post
                "multipart/mixed" to encodeMultipart(parts)
            }
            else -> "text/plain" to m.text.toByteArray()
        }
        val id = runCatching { node.sendMessage(to.address, ctBody.first, ctBody.second, true) }.getOrNull()
        onUi {
            val i = messages.indexOfFirst { it.localId == m.localId }
            if (i >= 0) messages[i] = m.copy(failed = false, delivered = false, bundleId = id,
                sentAt = System.currentTimeMillis())
        }
        pump()
    }

    // ---- node <-> radio plumbing (all on the hop.core thread) ---------------

    private fun addLink(socket: BluetoothSocket, initiator: Boolean) = core.post {
        val id = nextLinkId++
        val remoteAddr = runCatching { socket.remoteDevice?.address }.getOrNull()
        val link = HopLink(id, socket,
            onBytes = { lid, data -> core.post {
                linkRx[lid] = (linkRx[lid] ?: 0L) + data.size                     // DIAG handshake-flow
                node.received(lid, data); pump()
            } },
            onClose = { lid -> core.post {
                android.util.Log.i("HOPLOG", "ble link CLOSED id=$lid tx=${linkTx[lid] ?: 0L} rx=${linkRx[lid] ?: 0L}") // DIAG
                linkTx.remove(lid); linkRx.remove(lid)
                links.remove(lid)
                remoteAddr?.let {
                    connecting.remove(it); dialing.remove(it)
                    // Brief backoff before re-dialing a just-dropped peer, so a flapping link doesn't
                    // re-dial instantly and churn the radio.
                    dialBackoffUntil[it] = System.currentTimeMillis() + DIAL_BACKOFF_MIN_MS
                }
                node.disconnected(lid); scheduleRefresh()
            } })
        links[id] = link
        node.connected(id, initiator)
        android.util.Log.i("HOPLOG", "hop link UP id=$id initiator=$initiator remote=$remoteAddr")
        onUi { status.value = "linked (${if (initiator) "central" else "peripheral"})" }
        pump()
    }

    // ---- LAN bearer (mDNS/NSD + TCP) + Wi-Fi Direct -------------------------

    /// Stand up the LAN transport: one TCP server (shared by NSD and Wi-Fi Direct), an NSD service
    /// advertising our base58 address on the fixed port, and NSD discovery that dials peers we should
    /// initiate to (lower base58 dials). Plain TCP + length framing → bridges to iOS's Network.framework.
    private fun startLan() {
        // One TCP server accepts inbound links for BOTH NSD peers and Wi-Fi Direct clients (it binds
        // 0.0.0.0, so the Wi-Fi Direct group-owner interface is covered too).
        runCatching {
            val srv = java.net.ServerSocket()
            srv.reuseAddress = true
            srv.bind(java.net.InetSocketAddress(LAN_PORT))
            lanServer = srv
            thread(name = "lan-accept") {
                while (true) {
                    val sock = runCatching { srv.accept() }.getOrNull() ?: break
                    addLanLink(sock, initiator = false, name = null)   // we accept → Noise responder
                }
            }
        }.onFailure { android.util.Log.w("HOPLOG", "lan server bind failed: $it") }

        val nsd = context.getSystemService(android.net.nsd.NsdManager::class.java) ?: return
        nsdManager = nsd
        val info = android.net.nsd.NsdServiceInfo().apply {
            serviceName = myAddressVal        // instance name = our base58 address
            serviceType = LAN_SERVICE
            port = LAN_PORT
        }
        val reg = object : android.net.nsd.NsdManager.RegistrationListener {
            override fun onServiceRegistered(s: android.net.nsd.NsdServiceInfo) {}
            override fun onRegistrationFailed(s: android.net.nsd.NsdServiceInfo, e: Int) {
                android.util.Log.w("HOPLOG", "nsd register failed: $e")
            }
            override fun onServiceUnregistered(s: android.net.nsd.NsdServiceInfo) {}
            override fun onUnregistrationFailed(s: android.net.nsd.NsdServiceInfo, e: Int) {}
        }
        nsdRegListener = reg
        runCatching { nsd.registerService(info, android.net.nsd.NsdManager.PROTOCOL_DNS_SD, reg) }

        val disc = object : android.net.nsd.NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(t: String) {}
            override fun onDiscoveryStopped(t: String) {}
            override fun onStartDiscoveryFailed(t: String, e: Int) { android.util.Log.w("HOPLOG", "nsd discover failed: $e") }
            override fun onStopDiscoveryFailed(t: String, e: Int) {}
            override fun onServiceFound(s: android.net.nsd.NsdServiceInfo) {
                val name = s.serviceName ?: return
                core.post {
                    if (name == myAddressVal) return@post                 // not ourselves
                    if (myAddressVal >= name) return@post                 // tiebreak: lower base58 dials
                    if (lanDialed.containsKey(name)) return@post          // already dialing/linked
                    resolveAndDial(s, name)
                }
            }
            override fun onServiceLost(s: android.net.nsd.NsdServiceInfo) {}
        }
        nsdDiscListener = disc
        runCatching { nsd.discoverServices(LAN_SERVICE, android.net.nsd.NsdManager.PROTOCOL_DNS_SD, disc) }
        android.util.Log.i("HOPLOG", "lan start: ${myAddressVal.take(8)}")
    }

    /// Stand up the Wi-Fi Direct bearer (Android↔Android with no shared network). Client sockets it
    /// dials are wrapped as LanLinks (initiator); the group owner accepts on the shared TCP server.
    private fun startWifiDirect() {
        wifiDirect = WifiDirectBearer(context, core, { myAddressVal }, LAN_PORT,
            alreadyLinked = { isDirectlyLinked(it) },
            // Only run Wi-Fi Direct when NOT on a Wi-Fi network — on Wi-Fi, NSD/LAN links Android↔
            // Android and P2P scanning would just contend the 2.4 GHz radio with BLE (DESIGN.md §26).
            shouldRun = { !isOnWifiNetwork() }) { sock ->
            addLanLink(sock, initiator = true, name = null)   // we dialed the group owner → initiator
        }.also { runCatching { it.start() }.onFailure { e -> android.util.Log.w("HOPLOG", "wifi-direct start failed: $e") } }
    }

    /// Whether we already have a live non-relay link (BLE or LAN) to this base58 peer — used to
    /// skip a redundant Wi-Fi Direct group when the peer is reachable on a shared Wi-Fi via NSD.
    private fun isDirectlyLinked(base58: String): Boolean =
        runCatching { node.peerLinks() }.getOrDefault(emptyList())
            .any { it.link != relayLinkId && addressBase58(it.address) == base58 }

    /// True when this device is connected to a Wi-Fi network (any network with WIFI transport).
    /// Used to gate Wi-Fi Direct: it's only worth its radio cost when there's no shared network.
    private fun isOnWifiNetwork(): Boolean = runCatching {
        val cm = context.getSystemService(android.net.ConnectivityManager::class.java) ?: return false
        cm.allNetworks.any { n ->
            cm.getNetworkCapabilities(n)?.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI) == true
        }
    }.getOrDefault(false)

    /// Resolve an NSD service to host:port and dial it on a background thread. `resolveService` is
    /// one-at-a-time on older APIs, so we serialize with a flag and retry on the next discovery tick.
    private fun resolveAndDial(svc: android.net.nsd.NsdServiceInfo, name: String) {
        val nsd = nsdManager ?: return
        if (resolvingNsd) return
        resolvingNsd = true
        lanDialed[name] = 0u   // reserve so we don't double-dial while resolving
        nsd.resolveService(svc, object : android.net.nsd.NsdManager.ResolveListener {
            override fun onResolveFailed(s: android.net.nsd.NsdServiceInfo, e: Int) {
                core.post { resolvingNsd = false; lanDialed.remove(name) }
            }
            override fun onServiceResolved(s: android.net.nsd.NsdServiceInfo) {
                core.post { resolvingNsd = false }
                thread(name = "lan-dial") {
                    val sock = runCatching {
                        java.net.Socket().apply { connect(java.net.InetSocketAddress(s.host, s.port), 5000) }
                    }.getOrNull()
                    if (sock == null) { core.post { lanDialed.remove(name) }; return@thread }
                    addLanLink(sock, initiator = true, name = name)   // we dialed → Noise initiator
                    android.util.Log.i("HOPLOG", "lan dial ${name.take(8)}")
                }
            }
        })
    }

    private fun addLanLink(socket: java.net.Socket, initiator: Boolean, name: String?) = core.post {
        // Wi-Fi Direct always puts the group owner at 192.168.49.1 (the p2p interface subnet), so a
        // peer address in 192.168.49.0/24 means this is a P2P link, not a shared-network LAN link.
        val p2p = socket.inetAddress?.hostAddress?.startsWith("192.168.49.") == true
        val id = if (p2p) wifiDirectNextLinkId++ else lanNextLinkId++
        val link = LanLink(id, socket,
            onBytes = { lid, data -> core.post { node.received(lid, data); pump() } },
            onClose = { lid -> core.post {
                lanLinks.remove(lid)
                name?.let { lanDialed.remove(it) }
                node.disconnected(lid); scheduleRefresh()
            } })
        lanLinks[id] = link
        name?.let { lanDialed[it] = id }
        node.connected(id, initiator)
        android.util.Log.i("HOPLOG", "${if (p2p) "p2p" else "lan"} link UP id=$id initiator=$initiator")
        onUi { status.value = "linked (${if (p2p) "wifi-direct" else "lan"} ${if (initiator) "client" else "host"})" }
        pump()
    }

    private fun pump() {
        for (pkt in node.drainOutgoing()) {
            // Shared BearerManager (BLE + LAN) owns this link → route to it, then the legacy fallback.
            if (bearerLinks.contains(pkt.link.toLong())) { bearerMgr.send(pkt.bytes, pkt.link.toLong()); continue }
            val t = if (pkt.bytes.isNotEmpty()) (pkt.bytes[0].toInt() and 0xff) else 3   // LinkPacket discriminant
            val h = pktHisto.getOrPut(pkt.link) { LongArray(4) }
            h[if (t in 0..2) t else 3]++
            val link = links[pkt.link]
            if (link != null) { link.send(pkt.bytes); linkTx[pkt.link] = (linkTx[pkt.link] ?: 0L) + pkt.bytes.size }
            else if (pkt.link == relayLinkId) relaySend(pkt.bytes)
            else if (gattLinks.containsKey(pkt.link)) gattLinks[pkt.link]?.send(pkt.bytes)  // GATT-data fallback
            else lanLinks[pkt.link]?.send(pkt.bytes)   // LAN / Wi-Fi Direct TCP link
        }
        scheduleRefresh()
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
            val msg = Message(localId = nextMsgId++, peer = addressBase58(m.from), text = text,
                incoming = true, contentType = m.contentType,
                imageData = if (isImage) m.body else null, images = images,
                hops = m.hops, latencyMs = latency, trace = m.trace.map { traceLabel(it) })
            queueIdentify(m.from)   // learn the sender's display name (§29)
            // Someone who messages us joins the address book, so their conversation is reachable.
            val k = m.from.toList()
            if (!contacts.containsKey(k)) {
                contacts[k] = Peer(m.from, who, 0u, active = false)
                saveContacts(force = true)
            }
            val notifyText = if (isImage) "📷 Photo" else text
            onUi {   // UI-visible result → main thread
                messages.add(msg)
                if (!appInForeground) { unread.intValue += 1; notify(who, notifyText) }
            }
        }
        saveMessages()
        drainHps()       // pub/sub messages (§32)
        drainHns()       // HNS lookups + hops:// responses (§30)
        drainServices()  // hop.identify replies + custom service calls (§29)
        // (relay-queue diagnostics now refresh on the coalesced scheduleRefresh path, not per-frame)
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
        if (h.node.all { it == 0.toByte() }) return h.appLabel   // anonymized device hop (§27)
        val name = nameByAddr[h.node.toList()]
        return name ?: "${h.appLabel} ${shortHex(h.node)}"
    }

    private fun drainServices() {
        val logLines = ArrayList<String>()
        for (resp in node.takeServiceResponses()) {
            val info = if (identifyReqs.remove(resp.forRequestId.toList()) && resp.status == 0u.toUShort())
                runCatching { decodeIdentity(resp.body) }.getOrNull() else null
            if (info != null) {
                val label = info.name.ifEmpty { shortHex(info.address) }
                nameByAddr[info.address.toList()] = label
                logLines.add("identify ← $label (${info.kind})")
                scheduleRefresh()
            } else {
                logLines.add("service ← ${resp.status}: ${String(resp.body).take(120)}")
            }
        }
        for (req in node.takeServiceRequests()) {
            // No custom services in the demo — reply 501 so the caller isn't left hanging.
            logLines.add("service → ${req.service}/${req.method} (501)")
            runCatching { node.sendServiceResponse(req.from, req.requestId, 501u, ByteArray(0)) }
        }
        if (logLines.isEmpty()) return
        onUi {
            for (line in logLines) serviceLog.add(0, line)
            while (serviceLog.size > 100) serviceLog.removeAt(serviceLog.size - 1)
        }
    }

    private fun refreshQueue() {
        val rows = runCatching { node.queue() }.getOrDefault(emptyList()).map { q ->
            QueueRow(q.own, if (q.to.isEmpty()) "egress" else shortHex(q.to), q.priority, q.hops)
        }
        onUi { queue.clear(); queue.addAll(rows) }
    }

    fun clearQueue() = core.post {
        runCatching { node.clearQueue() }
        // Anything of ours still in flight is now abandoned — mark those "not sent" instead of
        // leaving them stuck on "Sending…".
        onUi {
            for (i in messages.indices) {
                val m = messages[i]
                if (!m.incoming && !m.delivered && !m.failed) messages[i] = m.copy(failed = true)
            }
        }
        saveMessages()   // core; debounced write picks up the onUi mutation
        refreshQueue()
    }

    // ---- hps:// pub/sub (DESIGN.md §32) -------------------------------------

    fun hpsRegister(path: String, channel: Boolean,
                    access: uniffi.hop.HpsAccess = uniffi.hop.HpsAccess.OPEN,
                    discoverable: Boolean = false) = core.post {
        val p = path.trim(); if (p.isEmpty()) return@post
        runCatching {
            node.registerService(p, if (channel) HpsKind.CHANNEL else HpsKind.SERVICE, access,
                if (discoverable) uniffi.hop.HpsVisibility.DISCOVERABLE else uniffi.hop.HpsVisibility.PRIVATE)
        }
        val topic = HpsTopic(node.address(), p, channel, hosting = true, access = access)
        onUi { if (hpsTopics.none { it.host.contentEquals(topic.host) && it.path == p }) hpsTopics.add(0, topic) }
    }

    fun hpsSubscribe(hostB58: String, path: String) = core.post {
        val host = runCatching { addressFromBase58(hostB58.trim()) }.getOrNull() ?: return@post
        val p = path.trim(); if (host.size != 32 || p.isEmpty()) return@post
        hpsSubscribeTo(host, p, channel = true)
    }

    private fun hpsSubscribeTo(host: ByteArray, path: String, channel: Boolean) {
        runCatching { node.hpsSubscribe(host, path) }
        val topic = HpsTopic(host, path, channel = channel, hosting = false)
        onUi { if (hpsTopics.none { it.host.contentEquals(host) && it.path == path }) hpsTopics.add(0, topic) }
        pump()
    }

    fun hpsJoin(t: uniffi.hop.HpsTopicInfo) = core.post {
        hpsSubscribeTo(t.host, t.path, t.kind == HpsKind.CHANNEL)
    }

    fun hpsPublish(topic: HpsTopic, text: String) = core.post {
        if (text.isEmpty()) return@post
        runCatching { node.hpsPublish(topic.path, text.toByteArray()) }
        appendThread(topic.id, HpsMsg(nextMsgId++, topic.path, node.address(), text)) // echo
        pump()
    }

    fun hpsInvite(topic: HpsTopic, to: ByteArray) = core.post {
        if (!topic.hosting || to.size != 32) return@post
        runCatching { node.hpsInvite(topic.path, to) }; pump()
    }

    fun hpsAcceptInvite(inv: uniffi.hop.HpsInvite) = core.post {
        runCatching { node.hpsAcceptInvite(inv.host, inv.path) }
        val topic = HpsTopic(inv.host, inv.path, inv.kind == HpsKind.CHANNEL, hosting = false)
        onUi {
            hpsInvites.removeAll { it.path == inv.path && it.host.contentEquals(inv.host) }
            if (hpsTopics.none { it.host.contentEquals(inv.host) && it.path == inv.path }) hpsTopics.add(0, topic)
        }
        pump()
    }

    fun hpsDeclineInvite(inv: uniffi.hop.HpsInvite) = core.post {
        runCatching { node.hpsDeclineInvite(inv.host, inv.path) } // durable: won't reappear
        onUi { hpsInvites.removeAll { it.path == inv.path && it.host.contentEquals(inv.host) } }
    }

    fun hpsPending(topic: HpsTopic): List<ByteArray> = runCatching { node.hpsPending(topic.path) }.getOrDefault(emptyList())
    fun hpsApprove(topic: HpsTopic, who: ByteArray) = core.post { runCatching { node.hpsApprove(topic.path, who) }; pump() }
    fun hpsDeny(topic: HpsTopic, who: ByteArray) = core.post { runCatching { node.hpsDeny(topic.path, who) } }
    fun hpsReach(topic: HpsTopic): Int = runCatching { node.hpsReach(topic.path).toInt() }.getOrDefault(0)
    fun hpsMembers(topic: HpsTopic): List<ByteArray> = runCatching { node.hpsMembers(topic.path) }.getOrDefault(emptyList())
    fun hpsRekey(topic: HpsTopic, remove: List<ByteArray> = emptyList()) = core.post { runCatching { node.hpsRekey(topic.path, "", remove) }; pump() }
    fun hpsBrowse(): List<uniffi.hop.HpsTopicInfo> = runCatching { node.browseDiscoverable() }.getOrDefault(emptyList())

    /// Rebuild the channel list from the node's persisted topics (hosted + subscribed) at startup.
    private fun loadHpsTopics() {
        val topics = runCatching { node.hpsMyTopics() }.getOrDefault(emptyList()).map { t ->
            HpsTopic(t.host, t.path, t.kind == HpsKind.CHANNEL, t.hosting, t.access)
        }
        onUi { topics.forEach { topic -> if (hpsTopics.none { it.id == topic.id }) hpsTopics.add(topic) } }
    }

    fun hpsLeave(topic: HpsTopic) = core.post {
        runCatching { node.hpsLeave(topic.path) }
        onUi {
            hpsTopics.removeAll { it.id == topic.id }
            hpsThreads.remove(topic.id); hpsUnread.remove(topic.id)
        }
        pump()
    }

    fun openTopic(id: String) { activeTopic = id; hpsUnread[id] = 0 }
    fun closeTopic() { activeTopic = null }

    /// Resolved display name for an address (its set name, or a short base58 prefix).
    fun displayName(addr: ByteArray): String = nameByAddr[addr.toList()] ?: shortHex(addr)
    /// Known peers as an invite-picker list (sorted by name).
    val contactList: List<Peer> get() = peers.sortedBy { it.name.lowercase() }

    private fun appendThread(id: String, m: HpsMsg) {
        onUi {
            val list = hpsThreads.getOrPut(id) { mutableStateListOf() }
            list.add(m)
            if (list.size > 500) list.removeAt(0)
        }
        saveChannels()
    }

    // ---- channel-thread persistence (survives restart) ----------------------
    private val channelsFile get() = java.io.File(context.filesDir, "channels.json")
    private var channelSaveScheduled = false
    private fun saveChannels() {
        if (channelSaveScheduled) return
        channelSaveScheduled = true
        core.postDelayed({ channelSaveScheduled = false; writeChannels() }, 1000)
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
        val loaded = LinkedHashMap<String, List<HpsMsg>>()
        for (id in root.keys()) {
            val arr = root.optJSONArray(id) ?: continue
            val msgs = ArrayList<HpsMsg>()
            for (i in 0 until arr.length()) {
                val o = arr.getJSONObject(i)
                msgs.add(HpsMsg(nextMsgId++, o.optString("path", ""),
                    android.util.Base64.decode(o.optString("sender", ""), android.util.Base64.NO_WRAP),
                    o.optString("text", "")))
            }
            loaded[id] = msgs
        }
        onUi { for ((id, msgs) in loaded) hpsThreads[id] = mutableStateListOf<HpsMsg>().apply { addAll(msgs) } }
    }

    private fun drainHps() {
        for (m in node.takeHpsMessages()) {
            val topic = hpsTopics.firstOrNull { it.path == m.path }
            val id = topic?.id ?: m.path
            appendThread(id, HpsMsg(nextMsgId++, m.path, m.sender, String(m.body)))
            onUi { if (id != activeTopic) hpsUnread[id] = (hpsUnread[id] ?: 0) + 1 }
        }
        for (inv in node.takeHpsInvites()) {
            onUi {
                if (hpsInvites.none { it.path == inv.path && it.host.contentEquals(inv.host) })
                    hpsInvites.add(inv)
            }
        }
    }

    // ---- HNS & hops:// (DESIGN.md §30) -------------------------------------

    /// Open `hops://<domain>/<path>` (bare `<domain>` ok): resolve via HNS, then GET over the mesh.
    fun openHops(input: String) = core.post {
        val (domain, path) = parseHops(input)
        if (domain.isEmpty()) { onUi { hopsResults["?"] = "error: not a hops:// url" }; return@post }
        onUi { hopsResults[domain] = "resolving…" }
        when (val r = node.resolveHns(domain)) {
            is HnsLookupResult.Cached ->
                if (r.address.isEmpty()) onUi { hopsResults[domain] = "error: no hops endpoint for $domain" }
                else fireHops(domain, path, r.address)
            is HnsLookupResult.Pending -> pendingHops[domain] = path
            is HnsLookupResult.NeedsResolver ->
                onUi { hopsResults[domain] = "error: offline — no internet or peers to resolve $domain" }
        }
        pump()
    }

    private fun fireHops(domain: String, path: String, endpoint: ByteArray) {
        nameByAddr[endpoint.toList()] = domain // label the endpoint by its domain (endpoints list/traces)
        val id = runCatching {
            node.sendHopsRequest(endpoint, domain, "GET", path, ByteArray(0), 8u * 1024u * 1024u)
        }.getOrNull()
        if (id == null) { onUi { hopsResults[domain] = "error: could not send request to $domain" }; return }
        hopsReqs[id.toList()] = domain
        onUi { hopsResults[domain] = "fetching…" }
        pump()
    }

    // hops:// for the WebView (callback-style, per resource — DESIGN.md §30).
    private val hopsWebPending = HashMap<String, MutableList<Pair<String, (Int, String, ByteArray) -> Unit>>>()
    private val hopsWebReqs = HashMap<List<Byte>, (Int, String, ByteArray) -> Unit>()

    /// Fetch one hops:// resource for the WebView, calling back with (status, contentType, body).
    fun hopsFetch(url: String, cb: (Int, String, ByteArray) -> Unit) {
        core.post {
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
            if (rec.address.isEmpty()) { val d = rec.domain; onUi { hopsResults[d] = "error: no hops endpoint for $d" } }
            else fireHops(rec.domain, path, rec.address)
        }
        for (resp in node.takeHttpResponses()) {
            val webCb = hopsWebReqs.remove(resp.forRequestId.toList())
            if (webCb != null) { webCb(resp.status.toInt(), resp.contentType, resp.body); continue }
            val domain = hopsReqs.remove(resp.forRequestId.toList()) ?: continue
            val line = "${resp.status} · ${String(resp.body)}"
            onUi { hopsResults[domain] = line }
        }
        // Host DNS hook (§30): fetch each requested domain's full DNSSEC chain over DoH and hand
        // core the raw bodies — core validates to the root anchors and decides the address.
        for (domain in node.takeDnsLookups()) fetchDnssecChain(domain)
        // Refresh the cache debug view.
        val cacheRows = runCatching { node.hnsCache() }.getOrDefault(emptyList())
            .map { HnsCacheRow(it.domain, it.address, it.ttlSecs) }
        onUi { hnsCache.clear(); hnsCache.addAll(cacheRows) }
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
                    if (remaining.decrementAndGet() == 0) core.post {
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
        core.post { connectRelay(pinned ?: config.relayUrl) }   // connectRelayWS/Tcp tears down the old link first
    }

    fun connectRelay(input: String) {
        val t = input.trim()
        if (t.isEmpty() || !config.relaysEnabled) { onUi { relayStatus.value = "disabled" }; return }  // pure-P2P mode
        relayUrl = t   // remembered so the tick loop auto-reconnects on drop (§28)
        if (t.startsWith("ws://") || t.startsWith("wss://")) connectRelayWS(t)
        else connectRelayTcp(t)
    }

    private fun connectRelayWS(url: String) {
        teardownRelay()
        onUi { relayStatus.value = "connecting…" }
        val client = OkHttpClient.Builder().build()
        relayWS = client.newWebSocket(Request.Builder().url(url).build(), object : WebSocketListener() {
            override fun onOpen(ws: WebSocket, response: Response) { core.post {
                android.util.Log.i("HOPLOG", "relay connected: $url")
                onUi { relayStatus.value = "connected" }; relayConnected = true
                node.connected(relayLinkId, true); pump()
            } }
            override fun onMessage(ws: WebSocket, bytes: ByteString) { core.post {
                node.received(relayLinkId, bytes.toByteArray()); pump()   // one frame = one packet
            } }
            override fun onClosing(ws: WebSocket, code: Int, reason: String) { core.post {
                android.util.Log.i("HOPLOG", "relay closing: $code $reason")
                onUi { relayStatus.value = "disconnected" }; relayDown()
            } }
            override fun onFailure(ws: WebSocket, t: Throwable, response: Response?) { core.post {
                android.util.Log.w("HOPLOG", "relay failed: ${t.message}", t)
                onUi { relayStatus.value = "failed: ${t.message}" }; relayDown()
            } }
        })
    }

    private fun connectRelayTcp(hostPort: String) {
        val parts = hostPort.split(":")
        val port = parts.getOrNull(1)?.toIntOrNull()
        if (parts.size != 2 || port == null) { onUi { relayStatus.value = "bad address" }; return }
        teardownRelay()
        onUi { relayStatus.value = "connecting…" }
        thread(isDaemon = true) {
            try {
                val sock = java.net.Socket(parts[0], port).apply { tcpNoDelay = true }
                relaySocket = sock
                relayOut = sock.getOutputStream()
                relayWriter = Executors.newSingleThreadExecutor()
                val inp = java.io.DataInputStream(sock.getInputStream())
                core.post {
                    onUi { relayStatus.value = "connected" }; relayConnected = true
                    node.connected(relayLinkId, true); pump()
                }
                val hdr = ByteArray(4)
                while (true) {
                    inp.readFully(hdr)
                    val n = (hdr[0].toInt() and 0xff shl 24) or (hdr[1].toInt() and 0xff shl 16) or
                            (hdr[2].toInt() and 0xff shl 8) or (hdr[3].toInt() and 0xff)
                    if (n <= 0 || n > (1 shl 20)) break
                    val buf = ByteArray(n); inp.readFully(buf)
                    core.post { node.received(relayLinkId, buf); pump() }
                }
            } catch (_: Exception) {
                core.post { if (relayStatus.value == "connected") onUi { relayStatus.value = "disconnected" } }
            } finally {
                core.post { relayDown() }
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
    private val contactsFile get() = java.io.File(context.filesDir, "contacts.json")
    private var lastContactSaveMs = 0L

    /// Add a contact by base58 address (manual entry or scanned QR). Returns false if invalid.
    /// An empty name resolves via hop.identify; a provided name is kept as the local alias.
    fun addContact(name: String, base58: String): Boolean {
        val addr = runCatching { addressFromBase58(base58.trim()) }.getOrNull() ?: return false
        if (addr.size != 32 || addr.contentEquals(node.address())) return false
        val alias = name.trim()
        core.post {
            rememberContact(Peer(addr, alias.ifEmpty { shortHex(addr) }, 0u, active = false))
            if (alias.isEmpty()) runCatching { queueIdentify(addr) }
            pump()
        }
        return true
    }

    /// Add a peer to the address book and persist now (e.g. on send) so the conversation is reachable.
    fun rememberContact(p: Peer) {
        contacts[p.address.toList()] = p
        nameByAddr[p.address.toList()] = p.name
        saveContacts(force = true)
    }
    private fun saveContacts(force: Boolean = false) {
        val now = System.currentTimeMillis()
        if (!force && now - lastContactSaveMs < 4000) return   // throttle (refresh runs often)
        lastContactSaveMs = now
        val arr = org.json.JSONArray()
        for (p in contacts.values) {
            arr.put(org.json.JSONObject()
                .put("addr", addressBase58(p.address)).put("name", p.name)
                .put("platform", p.platform).put("app", p.app))
        }
        val json = arr.toString()
        thread(name = "save-contacts") { runCatching { contactsFile.writeText(json) } }  // off the main thread
    }
    private fun loadContacts() {
        val txt = runCatching { contactsFile.readText() }.getOrNull() ?: return
        val arr = runCatching { org.json.JSONArray(txt) }.getOrNull() ?: return
        for (i in 0 until arr.length()) {
            val o = arr.getJSONObject(i)
            val addr = runCatching { addressFromBase58(o.getString("addr")) }.getOrNull() ?: continue
            if (addr.size != 32) continue
            val key = addr.toList()
            if (contacts.containsKey(key)) continue
            val name = o.optString("name", shortHex(addr))
            contacts[key] = Peer(addr, name, 0u, active = false,
                platform = o.optString("platform", ""), app = o.optString("app", ""))
            nameByAddr[key] = name
        }
    }
    private var saveScheduled = false

    /// Coalesce rapid mutations into one disk write (~1/sec) so a burst of messages — or the
    /// per-tick pump() — doesn't re-encode the whole history each time.
    private fun saveMessages() {
        if (saveScheduled) return
        saveScheduled = true
        core.postDelayed({ saveScheduled = false; writeMessages() }, 1000)
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
            m.deliveryMs?.let { o.put("deliveryMs", it.toLong()) } // forward-path (A→B) latency
            o.put("failed", m.failed)
            // Keep the bundleId: the node re-sprays undelivered own-bundles after restart (node.rs
            // rehydrate); persisting it lets refresh() re-query messageStatus and flip to Delivered.
            m.bundleId?.let { o.put("bundleId", android.util.Base64.encodeToString(it, android.util.Base64.NO_WRAP)) }
            arr.put(o)
        }
        runCatching { messagesFile.writeText(arr.toString()) }
    }

    private fun loadMessages() {
        val txt = runCatching { messagesFile.readText() }.getOrNull() ?: return
        val arr = runCatching { org.json.JSONArray(txt) }.getOrNull() ?: return
        val loaded = ArrayList<Message>()
        for (i in 0 until arr.length()) {
            val o = arr.getJSONObject(i)
            val incoming = o.getBoolean("incoming")
            val delivered = o.optBoolean("delivered", false)
            val imgs = o.optJSONArray("images")?.let { a ->
                (0 until a.length()).map { android.util.Base64.decode(a.getString(it), android.util.Base64.NO_WRAP) }
            } ?: emptyList()
            val trace = o.optJSONArray("trace")?.let { a -> (0 until a.length()).map { a.getString(it) } } ?: emptyList()
            loaded.add(Message(
                localId = nextMsgId++, peer = o.getString("peer"), text = o.optString("text", ""),
                incoming = incoming, contentType = o.optString("contentType", "text/plain"),
                imageData = if (o.has("imageData")) android.util.Base64.decode(o.getString("imageData"), android.util.Base64.NO_WRAP) else null,
                images = imgs, hops = o.optInt("hops", 0).toUByte(),
                latencyMs = if (o.has("latencyMs")) o.getLong("latencyMs").toULong() else null,
                trace = trace, sentAt = o.optLong("sentAt", System.currentTimeMillis()),
                deliveredAt = if (o.has("deliveredAt")) o.getLong("deliveredAt") else null,
                relayed = o.optLong("relayed", 0).toUInt(), delivered = delivered,
                deliveryHops = o.optInt("deliveryHops", 0).toUByte(),
                deliveryMs = if (o.has("deliveryMs")) o.getLong("deliveryMs").toULong() else null,
                // An outgoing message still in flight KEEPS sending after restart — the node re-sprays
                // it until its ACK (node.rs rehydrate). Restore it in-flight with its bundleId so
                // refresh() reconciles to Delivered when it lands, rather than falsely showing "not sent".
                failed = o.optBoolean("failed", false),
                bundleId = if (o.has("bundleId")) android.util.Base64.decode(o.getString("bundleId"), android.util.Base64.NO_WRAP) else null,
            ))
        }
        onUi { messages.addAll(loaded) }
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
            .setSmallIcon(config.notificationIcon)
            .setContentTitle(from)
            .setContentText(text)
            .setAutoCancel(true)
            .setNumber(unread.intValue)   // drives the launcher icon badge count
            .setBadgeIconType(NotificationCompat.BADGE_ICON_SMALL)
            .build()
        NotificationManagerCompat.from(context).notify(text.hashCode(), n)
    }

    @Volatile private var refreshScheduled = false

    /// Coalesced UI refresh. `refresh()` does synchronous SQLite work (browse, queue, per-message
    /// status) and is far too costly to run on every `pump()` — which fires on every received packet
    /// across BLE/Wi-Fi/LAN/relay. Per-packet refresh saturates the main thread (sluggish UI, ANRs).
    /// Coalesce to ~4 Hz; pump still drains outgoing + the inbox immediately, only this is throttled.
    private fun scheduleRefresh() {
        if (refreshScheduled) return
        refreshScheduled = true
        core.postDelayed({ refreshScheduled = false; refresh() }, 250)
    }

    /// Runs on core: all node reads happen here; the resulting UI state is applied in ONE onUi block.
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
        // Map each directly-linked peer to its transport: relay (20_000), Wi-Fi Direct/P2P (50_000+),
        // LAN over a shared network (40_000+), everything else a BLE link.
        val ltLocal = LinkedHashMap<List<Byte>, String>()
        val pls = runCatching { node.peerLinks() }.getOrDefault(emptyList())
        pls.forEach { pl ->
            // Shared-bearer links are minted by the BearerManager (baseLinkId 1_000_000+), so the legacy
            // link-id ranges below can't tag them — ask the manager for the owning bearer's REAL transport
            // first (BT / LAN / Wi-Fi Direct / Relay), then fall back to the legacy ranges for the links
            // the node still mints itself. (refresh() runs on core, so reading bearerLinks here is safe.)
            val sharedTag = if (bearerLinks.contains(pl.link.toLong())) bearerMgr.transportNameOf(pl.link.toLong()) else null
            ltLocal[pl.address.toList()] = sharedTag ?: when {
                pl.link == relayLinkId -> "Relay"
                pl.link >= 50_000u -> "P2P"
                pl.link >= 40_000u -> "LAN"
                else -> "BT"
            }
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
            val t = ltLocal[key]
            // Every shared/local radio link is a 1-hop direct path; "Relay" is the only non-direct tag.
            val hops = if (t == "BT" || t == "LAN" || t == "P2P" || t == "Wi-Fi Direct") 1u.toUByte() else it.minHops
            it.peer.copy(hops = hops)
        }.sortedBy { addressBase58(it.address) }

        // Address book: fold every live peer into the (persisted) contact book; the contacts NOT
        // currently reachable form the offline "seen" list, so past conversations stay reachable
        // even when the peer is offline / out of range / after a restart.
        for (p in list) contacts[p.address.toList()] = p
        val here = list.map { it.address.toList() }.toHashSet()
        val off = contacts.filterKeys { it !in here }.values
            .map { it.copy(hops = 0u, active = false) }
            .sortedBy { it.name.lowercase() }
        saveContacts()

        // Which peers we're talking to over a forward-secret session (lock icon).
        val securedLocal = list.filter { node.isSecured(it.address) }.map { it.address.toList() }

        // Delivery status for our outgoing messages: read the node here (core), apply by localId on
        // main. Each entry is the already-transformed copy (derived from the core-side snapshot).
        val now = System.currentTimeMillis()
        val msgUpdates = ArrayList<Pair<Long, Message>>()
        for (m in messages.toList()) {
            if (m.incoming || m.bundleId == null) continue
            val s = node.messageStatus(m.bundleId)
            if (s.delivered && m.deliveredAt == null) {
                msgUpdates.add(m.localId to m.copy(relayed = s.relayed, delivered = true,
                    deliveryHops = s.deliveryHops, deliveryMs = s.deliveryMs.toULong(), deliveredAt = now))
            } else if (s.relayed != m.relayed) {
                msgUpdates.add(m.localId to m.copy(relayed = s.relayed))
            }
        }

        onUi {
            linkTransports.clear(); linkTransports.putAll(ltLocal)
            peers.clear(); peers.addAll(list)
            seen.clear(); seen.addAll(off)
            secured.clear(); secured.addAll(securedLocal)
            for ((localId, updated) in msgUpdates) {
                val i = messages.indexOfFirst { it.localId == localId }
                if (i >= 0) messages[i] = updated
            }
        }
        refreshQueue()   // relay-queue diagnostics (was per-frame in pump; now on the coalesced path)
    }

    // ---- peripheral: advertise + accept L2CAP -------------------------------

    /// Watches the Bluetooth adapter so a wedged stack can be cleared by toggling BT (the proven
    /// recovery) WITHOUT a full app restart. On OFF we drop the now-dead peripheral handles; on ON
    /// we rebuild the L2CAP listener, GATT server, advertising, and beacon from scratch.
    private var btReceiverRegistered = false
    private val btStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, intent: Intent) {
            if (intent.action != BluetoothAdapter.ACTION_STATE_CHANGED) return
            when (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)) {
                BluetoothAdapter.STATE_OFF -> {
                    android.util.Log.i("HOPLOG", "BLE: adapter OFF → dropping stale peripheral handles")
                    core.post { teardownBlePeripheral() }   // touches core-owned peripheral state
                }
                BluetoothAdapter.STATE_ON -> {
                    // Let the stack settle before re-listening (listenUsingInsecureL2capChannel can
                    // fail if called the instant the adapter reports ON).
                    core.postDelayed({ restartBle() }, 800)
                }
            }
        }
    }

    private fun registerBtStateReceiver() {
        if (btReceiverRegistered) return
        runCatching {
            context.registerReceiver(btStateReceiver, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED))
            btReceiverRegistered = true
        }
    }

    /// Close the peripheral handles that go invalid when the adapter powers down. Closing the L2CAP
    /// server socket unblocks the accept thread so it exits its loop; nulling the advertising sets
    /// forces startAdvertise()/startBeacon() to re-arm (they early-return while the ref is non-null).
    private fun teardownBlePeripheral() {
        runCatching { serverSocket?.close() }
        serverSocket = null
        runCatching { gattServer?.close() }
        gattServer = null
        advSet = null
        beaconSet = null
        psm = -1
    }

    /// Re-initialize BLE after the adapter returns (or recovers from a wedge). Rebuilds the
    /// peripheral and clears central dial bookkeeping so we can re-dial peers immediately. The
    /// scan loop is self-sustaining (it reschedules itself), so it recovers on its own.
    private fun restartBle() {
        if (!started) return
        android.util.Log.i("HOPLOG", "BLE: adapter ON → re-initializing peripheral + central")
        teardownBlePeripheral()
        // Release any lingering advertising-set associations from the previous adapter session, then
        // swap in fresh callback instances so startAdvertise()/startBeacon() can register cleanly
        // (the framework rejects re-using a still-associated callback after a cycle).
        runCatching { adapter.bluetoothLeAdvertiser?.stopAdvertisingSet(advSetCallback) }
        runCatching { adapter.bluetoothLeAdvertiser?.stopAdvertisingSet(beaconSetCallback) }
        advSetCallback = makeAdvSetCallback()
        beaconSetCallback = makeBeaconSetCallback()
        // BLE dial state is per-adapter; every BLE socket died with the adapter, so clear it to
        // allow fresh dials. (LAN/relay links live in `links` under their own ids and are untouched.)
        connecting.clear()
        dialing.clear()
        dialBackoffUntil.clear()
        // GATT-data links died with the adapter too.
        gattLinks.keys.toList().forEach { closeGattLink(it) }
        gattMtu.clear()
        runCatching { startPeripheral() }
            .onFailure { android.util.Log.w("HOPLOG", "BLE re-init failed: $it") }
    }

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
                // No re-arm here: the connectable AdvertisingSet keeps advertising across connections,
                // so other centrals can still find + connect. Re-arming would reset the scan response
                // (dropping the name) and disrupt live connections (the old churn).
            }
        }

        val server = (context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager)
            .openGattServer(context, gattServerCallback)
        val service = BluetoothGattService(SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        // ONE characteristic only — the L2CAP PSM (Ditto mechanism A). The central reads this, then
        // opens L2CAP; all data rides L2CAP, never GATT. (An over-built service with an extra
        // write+indicate DATA char stalled CoreBluetooth's targeted discovery/read.)
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
        startBeacon()   // second set: iBeacon to wake backgrounded/killed iPhones (DESIGN.md §22)
        onUi { status.value = "advertising (psm $psm)" }
    }

    /// (Re)start connectable advertising. Called at startup and re-armed after each accepted
    /// connection, because legacy advertising stops on connect (so without this only one peer
    /// could ever link to us).
    private fun startAdvertise() {
        if (advSet != null) return   // already advertising — a connectable set persists across connections
        val adv = adapter.bluetoothLeAdvertiser ?: return
        // Carry the L2CAP PSM in the advertisement (manufacturer data, 2 bytes big-endian). iOS
        // reads it fresh from the scan and opens L2CAP DIRECTLY — skipping GATT service discovery,
        // which iOS caches by our BLE address and serves stale after an app restart (the "connects
        // but never reads PSM" stall). 18B (128-bit UUID) + 6B (mfg) + 3B (flags) = 27B, fits in 31.
        // Manufacturer data: [PSM 2B big-endian][advert id 4B]. iOS reads PSM (skip GATT) + our id
        // (role tiebreaker). 18B(UUID) + 12B(mfg: 2 hdr + 2 company + 2 psm + 4 id) + ... fits in 31.
        val data = AdvertiseData.Builder()
            .addServiceUuid(ParcelUuid(SERVICE_UUID))
            .addManufacturerData(HOP_MFG_ID, byteArrayOf((psm ushr 8).toByte(), psm.toByte()) + myAdvertId)
            .build()
        // The device name rides the SCAN RESPONSE (the 31-byte advert is full: UUID + PSM + flags).
        val scanResponse = AdvertiseData.Builder()
            .setIncludeDeviceName(true)   // system GAP name (e.g. "Pixel 7")
            .build()
        // Use the modern Advertising Set API in LEGACY mode: it emits the SAME ADV_IND packets iOS
        // already scans/connects to, but (1) reliably includes the device name in the scan response —
        // the legacy startAdvertising path silently drops it on many devices — and (2) a connectable
        // set keeps advertising across connections, so multiple centrals can connect without the
        // stop-on-connect/re-arm race that timed out LightBlue (CONNECTION_ACCEPT_TIMEOUT).
        val params = android.bluetooth.le.AdvertisingSetParameters.Builder()
            .setLegacyMode(true)
            .setConnectable(true)
            .setScannable(true)
            .setInterval(android.bluetooth.le.AdvertisingSetParameters.INTERVAL_LOW)
            .setTxPowerLevel(android.bluetooth.le.AdvertisingSetParameters.TX_POWER_MEDIUM)
            .build()
        runCatching { adv.startAdvertisingSet(params, data, scanResponse, null, null, advSetCallback) }
            .onFailure { android.util.Log.w("HOPLOG", "startAdvertisingSet threw: $it") }
    }

    /// Broadcast an iBeacon matching the region the iOS app monitors (UUID HOP_BEACON_UUID). iOS
    /// region monitoring fires on ENTRY even when the Hop app is backgrounded or KILLED, relaunching
    /// it — so this is how an Android device WAKES a nearby iPhone for cross-platform delivery (the
    /// iPhone can't be woken by a BLE connect: its backgrounded service UUID is in the Apple-only
    /// overflow area Android can't see). Runs as a SEPARATE non-connectable advertising set (the
    /// 25-byte iBeacon payload fills its own advert; it can't share the Hop service advert).
    private fun startBeacon() {
        if (beaconSet != null) return
        val adv = adapter.bluetoothLeAdvertiser ?: return
        // iBeacon manufacturer payload: 0x0215, 16-byte proximity UUID, 2-byte major, 2-byte minor,
        // 1-byte measured power. Company ID 0x004C (Apple) is what iOS recognizes as an iBeacon.
        val uuidBytes = ByteArray(16)
        val u = HOP_BEACON_UUID
        for (i in 0 until 8)  uuidBytes[i]     = (u.mostSignificantBits  ushr (56 - i * 8)).toByte()
        for (i in 0 until 8)  uuidBytes[i + 8] = (u.leastSignificantBits ushr (56 - i * 8)).toByte()
        val payload = byteArrayOf(0x02, 0x15) + uuidBytes +
            byteArrayOf(0x00, 0x00,   // major
                        0x00, 0x00,   // minor
                        0xC5.toByte()) // measured power (~-59 dBm)
        val data = AdvertiseData.Builder()
            .addManufacturerData(APPLE_MFG_ID, payload)   // 0x004C
            .build()
        val params = android.bluetooth.le.AdvertisingSetParameters.Builder()
            .setLegacyMode(true)
            .setConnectable(false)   // a beacon is a pure broadcast — iOS monitors the UUID, doesn't connect
            .setScannable(false)
            .setInterval(android.bluetooth.le.AdvertisingSetParameters.INTERVAL_MEDIUM)
            .setTxPowerLevel(android.bluetooth.le.AdvertisingSetParameters.TX_POWER_HIGH)  // range = wake distance
            .build()
        runCatching { adv.startAdvertisingSet(params, data, null, null, null, beaconSetCallback) }
            .onFailure { android.util.Log.w("HOPLOG", "iBeacon startAdvertisingSet threw: $it") }
    }

    // Devices currently connected to OUR GATT server (i.e. they're a central to us). We must NOT
    // also dial them as a central: two devices share one BLE ACL, and our central tearing its leg
    // down (failed dial / timeout) terminates the shared link — killing their inbound connection
    // mid-handshake (the dual-role conflict that caused "peer left" before the GATT-data fallback).
    private val gattServerClients = HashSet<String>()
    private val scanLogged = HashMap<String, Long>()   // DIAG: throttle scan logging per addr
    // Random per-launch advert ID for deterministic role assignment (Ditto's pattern): of any two
    // peers, the one with the LOWER id is the central (dials), the higher is the peripheral (waits).
    // Exactly one connection per pair → no dual-role ACL teardown. Identity-free (the Noise handshake
    // supplies the real id); transparent to BLE-address rotation. 4 bytes fits the 31-byte advert.
    private val myAdvertId: ByteArray = ByteArray(4).also { java.security.SecureRandom().nextBytes(it) }
    private fun idLessThan(a: ByteArray, b: ByteArray): Boolean {
        for (i in 0 until minOf(a.size, b.size)) {
            val ai = a[i].toInt() and 0xff; val bi = b[i].toInt() and 0xff
            if (ai != bi) return ai < bi
        }
        return a.size < b.size
    }

    private val gattServerCallback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            android.util.Log.i("HOPLOG", "BLE peripheral GATT: ${device.address} status=$status newState=$newState")
            core.post {
                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    gattServerClients.add(device.address)
                    // If we were mid-dial to this same device, drop our in-flight marker — their
                    // inbound connection carries the link now. One pipe per pair.
                    dialing.remove(device.address)
                    connecting.remove(device.address)
                } else {
                    gattServerClients.remove(device.address)
                }
            }
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

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
            gattMtu[device.address] = mtu
        }

        // A central enabled indications on the DATA characteristic → it's about to drive a GATT-data
        // link to us (the L2CAP fallback). Spin up our peripheral (responder) side now.
        override fun onDescriptorWriteRequest(
            device: BluetoothDevice, requestId: Int, descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray,
        ) {
            android.util.Log.i("HOPLOG", "peripheral onDescriptorWrite ${device.address} desc=${descriptor.uuid} char=${descriptor.characteristic?.uuid}")  // DIAG
            if (descriptor.uuid == CCCD_UUID && descriptor.characteristic.uuid == DATA_CHAR_UUID) {
                core.post { peripheralGattLinkFor(device) }
            }
            if (responseNeeded) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
            }
        }

        // Inbound GATT-data chunk (one ATT write) from a central → reassemble into Hop frames.
        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice, requestId: Int, characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray,
        ) {
            android.util.Log.i("HOPLOG", "peripheral onCharWrite ${device.address} char=${characteristic.uuid} ${value.size}B")  // DIAG
            if (characteristic.uuid == DATA_CHAR_UUID) {
                core.post { peripheralGattLinkFor(device).onChunkReceived(value) }
            }
            if (responseNeeded) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
            }
        }

        // Our indication was delivered + acked → the link can send its next chunk.
        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
            val id = deviceGattLink[device.address] ?: return
            core.post { gattLinks[id]?.onChunkSent() }
        }
    }

    /// Get (or create) the peripheral-side GATT-data link for a connected central. Creating it
    /// registers the link with the node as a Noise responder and wires its sends to indications.
    private fun peripheralGattLinkFor(device: BluetoothDevice): GattDataLink {
        deviceGattLink[device.address]?.let { gattLinks[it]?.let { l -> return l } }
        val id = nextGattLinkId++
        val link = GattDataLink(
            id = id,
            usablePayload = { (gattMtu[device.address] ?: 23) - 3 },
            sendChunk = { chunk ->
                val ch = peripheralDataChar ?: return@GattDataLink false
                ch.value = chunk
                @Suppress("DEPRECATION")
                gattServer?.notifyCharacteristicChanged(device, ch, true) == true  // true = indication (acked)
            },
            onBytes = { lid, data -> node.received(lid, data); pump() },
            onClose = { lid -> core.post { closeGattLink(lid) } },
        )
        gattLinks[id] = link
        gattLinkDevice[id] = device
        deviceGattLink[device.address] = id
        node.connected(id, false)   // peripheral = Noise responder
        android.util.Log.i("HOPLOG", "GATT-data link UP id=$id initiator=false remote=${device.address}")
        pump()
        return link
    }

    private fun closeGattLink(id: ULong) {
        gattLinks.remove(id)?.close()
        // Central link: drop the underlying GATT connection so the dial/backoff cycle rebuilds it
        // (a degraded link that just lingers never recovers — the "works then degrades" failure).
        gattLinkGatt.remove(id)?.let { gatt ->
            val addr = gatt.device.address
            runCatching { gatt.close() }
            connecting.remove(addr); dialFailed(addr)
        }
        gattLinkDevice.remove(id)?.let { deviceGattLink.remove(it.address) }
        node.disconnected(id); scheduleRefresh()
    }

    private var advSet: android.bluetooth.le.AdvertisingSet? = null
    // Recreated fresh on each (re)start: Android rejects re-registering a callback INSTANCE that's
    // still associated with a prior advertising set ("callback instance already associated with
    // advertising"), which broke re-arming after a BT adapter cycle. A new instance sidesteps that.
    private var advSetCallback = makeAdvSetCallback()
    private fun makeAdvSetCallback() = object : android.bluetooth.le.AdvertisingSetCallback() {
        override fun onAdvertisingSetStarted(set: android.bluetooth.le.AdvertisingSet?, txPower: Int, status: Int) {
            if (status == android.bluetooth.le.AdvertisingSetCallback.ADVERTISE_SUCCESS) {
                advSet = set
                android.util.Log.i("HOPLOG", "BLE advertising started (set, txPower=$txPower)")
            } else {
                android.util.Log.w("HOPLOG", "BLE advertising-set start FAILED: status=$status")
            }
        }
        override fun onAdvertisingSetStopped(set: android.bluetooth.le.AdvertisingSet?) {
            advSet = null   // allow the periodic self-heal in the tick loop to re-arm
            android.util.Log.i("HOPLOG", "BLE advertising set stopped")
        }
    }

    private var beaconSet: android.bluetooth.le.AdvertisingSet? = null
    private var beaconSetCallback = makeBeaconSetCallback()
    private fun makeBeaconSetCallback() = object : android.bluetooth.le.AdvertisingSetCallback() {
        override fun onAdvertisingSetStarted(set: android.bluetooth.le.AdvertisingSet?, txPower: Int, status: Int) {
            if (status == android.bluetooth.le.AdvertisingSetCallback.ADVERTISE_SUCCESS) {
                beaconSet = set
                android.util.Log.i("HOPLOG", "iBeacon advertising started (wakes backgrounded iPhones)")
            } else {
                android.util.Log.w("HOPLOG", "iBeacon advertising start FAILED: status=$status (multi-advert unsupported?)")
            }
        }
        override fun onAdvertisingSetStopped(set: android.bluetooth.le.AdvertisingSet?) { beaconSet = null }
    }

    // ---- central: scan + open L2CAP -----------------------------------------

    @Volatile private var scanning = false

    /// Bursty central: scan for SCAN_WINDOW, then idle SCAN_IDLE. The radio is in scan mode only
    /// ~25% of the time, so our peripheral role is reachable the rest — a continuous scan starved
    /// it (iOS couldn't connect to us). Bursts still discover peers so we can push to them.
    private fun startCentral() {
        scanBurst()
    }

    private fun scanBurst() {
        if (!started) return
        val scanner = adapter.bluetoothLeScanner ?: run {
            core.postDelayed({ scanBurst() }, SCAN_IDLE_MS); return
        }
        val filter = ScanFilter.Builder().setServiceUuid(ParcelUuid(SERVICE_UUID)).build()
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_POWER).build()
        runCatching { scanner.startScan(listOf(filter), settings, scanCallback); scanning = true }
        core.postDelayed({
            if (scanning) { runCatching { scanner.stopScan(scanCallback) }; scanning = false }
            core.postDelayed({ scanBurst() }, SCAN_IDLE_MS) // idle: radio free for the peripheral
        }, SCAN_WINDOW_MS)
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val device = result.device
            val peer = peerAdvert(result)
            // DIAG: what did we actually discover + parse? (throttled to once per addr per 10s)
            val now = System.currentTimeMillis()
            if (now - (scanLogged[device.address] ?: 0L) > 10_000L) {
                scanLogged[device.address] = now
                val mfg = result.scanRecord?.getManufacturerSpecificData(HOP_MFG_ID)
                val mine = myAdvertId.joinToString("") { "%02x".format(it) }
                val pid = peer?.id?.joinToString("") { "%02x".format(it) }
                android.util.Log.i("HOPLOG", "scan ${device.address} name=${result.scanRecord?.deviceName} mfg=${mfg?.size}B peer=${if (peer==null) "null" else "psm=${peer.psm} id=$pid ${if(peer.isAndroid)"a" else "i"}"} myId=$mine willDial=${peer!=null && idLessThan(myAdvertId, peer.id)}")
            }
            core.post { tryDial(device, peer) }   // gating + direct L2CAP on the hop.core thread
        }
        override fun onScanFailed(errorCode: Int) {
            android.util.Log.w("HOPLOG", "BLE scan FAILED: code=$errorCode")
        }
    }

    /// The peer's advert id, for the role tiebreaker. Android peers carry it in manufacturer data
    /// ([PSM 2B][id 4B]); iOS peers (which can't advertise mfg data) put it in the local name as hex.
    /// Returns null if unreadable (e.g. a backgrounded iOS peer whose name is in the scan overflow).
    /// A peer's advert: its L2CAP PSM, its random role id, and whether it's an Android peer.
    data class PeerAdvert(val psm: Int, val id: ByteArray, val isAndroid: Boolean)

    private fun peerAdvert(result: ScanResult): PeerAdvert? {
        // Android peer: mfg data [PSM 2B big-endian][id 4B].
        val mfg = result.scanRecord?.getManufacturerSpecificData(HOP_MFG_ID)
        if (mfg != null && mfg.size >= 6) {
            val psm = (mfg[0].toInt() and 0xff shl 8) or (mfg[1].toInt() and 0xff)
            return PeerAdvert(psm, mfg.copyOfRange(2, 6), isAndroid = true)
        }
        // iOS peer: local name = hex([PSM 2B][id 4B]) = 12 hex chars (iOS can't advertise mfg data).
        val name = result.scanRecord?.deviceName
        if (name != null && name.length == 12) {
            return runCatching {
                val bytes = ByteArray(6) { name.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
                val psm = (bytes[0].toInt() and 0xff shl 8) or (bytes[1].toInt() and 0xff)
                PeerAdvert(psm, bytes.copyOfRange(2, 6), isAndroid = false)
            }.getOrNull()
        }
        return null
    }

    /// Open an L2CAP channel (as central) directly to a peer's advertised PSM — no GATT at all
    /// (pure L2CAP). UNBIASED: a peer is just "a BLE peripheral advertising a PSM" — iOS, Android,
    /// Pi, ESP32, all the same. Random-id tiebreaker (one channel per pair): only the LOWER id is
    /// the central (dials); the higher waits as peripheral. GENTLY: cap concurrent dials + backoff.
    private fun tryDial(device: BluetoothDevice, peer: PeerAdvert?) {
        val addr = device.address
        if (peer == null) return                                            // no PSM/id (e.g. bg iOS) → can't open L2CAP
        if (connecting.contains(addr) || dialing.contains(addr)) return     // already linked / dialing it
        if (!idLessThan(myAdvertId, peer.id)) return                         // tiebreaker: only the lower id dials
        if (gattServerClients.contains(addr)) return                        // already a central to us — let it carry the link
        if (dialing.size >= MAX_DIALS_IN_FLIGHT) return                     // one or two outbound at a time
        if (System.currentTimeMillis() < (dialBackoffUntil[addr] ?: 0L)) return  // backing off this peer
        connecting.add(addr); dialing.add(addr)
        android.util.Log.i("HOPLOG", "BLE central: opening L2CAP to $addr psm=${peer.psm} (${if (peer.isAndroid) "android" else "ios"})")
        thread(name = "hop-l2cap-dial-$addr") {
            val socket = runCatching { device.createInsecureL2capChannel(peer.psm).apply { connect() } }
                .onFailure { android.util.Log.w("HOPLOG", "central L2CAP open to $addr FAILED: $it") }
                .getOrNull()
            core.post {
                if (socket == null) { dialFailed(addr); return@post }
                android.util.Log.i("HOPLOG", "central L2CAP OPEN ok to $addr")
                addLink(socket, initiator = true)
                dialSucceeded(addr)
            }
        }
    }

    private fun dialFailed(addr: String) {
        dialing.remove(addr); connecting.remove(addr)
        val step = ((dialBackoffStep[addr] ?: (DIAL_BACKOFF_MIN_MS / 2)) * 2).coerceIn(DIAL_BACKOFF_MIN_MS, DIAL_BACKOFF_MAX_MS)
        dialBackoffStep[addr] = step
        dialBackoffUntil[addr] = System.currentTimeMillis() + step
    }

    private fun dialSucceeded(addr: String) {
        dialing.remove(addr)   // handshake/L2CAP done; `connecting` keeps the live-link marker
        dialBackoffStep.remove(addr); dialBackoffUntil.remove(addr)  // it works — reset the backoff
    }

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, statusCode: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED && statusCode == BluetoothGatt.GATT_SUCCESS) {
                runCatching { gatt.requestMtu(517) }   // bigger ATT MTU = fewer GATT-data chunks (best-effort)
                gatt.discoverServices()
            } else {
                // Failed or dropped. MUST close to free the GATT client (Android caps them) and back
                // off this peer so we don't re-dial it on the very next scan and flood the radio.
                android.util.Log.i("HOPLOG", "BLE central: ${gatt.device.address} disconnected status=$statusCode state=$newState")
                // Tear down any GATT-data link riding this connection.
                val deadId = gattLinkGatt.entries.firstOrNull { it.value === gatt }?.key
                runCatching { gatt.close() }
                val addr = gatt.device.address
                core.post { deadId?.let { closeGattLink(it) }; dialFailed(addr) }
            }
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            gattMtu[gatt.device.address] = mtu
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, statusCode: Int) {
            val ch = gatt.getService(SERVICE_UUID)?.getCharacteristic(PSM_CHAR_UUID) ?: run {
                runCatching { gatt.close() }
                val a = gatt.device.address; core.post { dialFailed(a) }   // not a Hop peripheral / no PSM char
                return
            }
            gatt.readCharacteristic(ch)
        }

        @Deprecated("compat with API < 33")
        override fun onCharacteristicRead(
            gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, statusCode: Int,
        ) {
            val device = gatt.device
            val v = characteristic.value
            if (v == null || v.size < 2) {
                runCatching { gatt.close() }; core.post { dialFailed(device.address) }; return
            }
            // 2 bytes big-endian (matches iOS's UInt16 PSM).
            val psm = (v[0].toInt() and 0xff shl 8) or (v[1].toInt() and 0xff)
            android.util.Log.i("HOPLOG", "central read PSM=$psm from ${device.address} → opening L2CAP")  // DIAG
            thread(name = "hop-l2cap-connect") {
                val socket = runCatching {
                    device.createInsecureL2capChannel(psm).apply { connect() }
                }.onFailure { android.util.Log.w("HOPLOG", "central L2CAP open to ${device.address} FAILED: $it") }  // DIAG
                 .getOrNull()
                if (socket == null) {
                    // L2CAP couldn't open (Apple→Android always fails this way). DON'T drop the GATT
                    // connection — fall back to the GATT-data bearer over it instead.
                    android.util.Log.i("HOPLOG", "central L2CAP failed → GATT-data fallback to ${device.address}")
                    core.post { startCentralGattData(gatt) }
                    return@thread
                }
                android.util.Log.i("HOPLOG", "central L2CAP OPEN ok to ${device.address} psm=$psm")  // DIAG
                addLink(socket, initiator = true)             // GATT stays open to hold the link
                core.post { dialSucceeded(device.address) }   // it worked — clear the dial + backoff
            }
        }

        // GATT-data: our subscribe to the peer's DATA characteristic completed → bring the link up.
        @Deprecated("compat with API < 33")
        override fun onDescriptorWrite(
            gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int,
        ) {
            if (descriptor.uuid == CCCD_UUID && descriptor.characteristic.uuid == DATA_CHAR_UUID) {
                core.post { gattDataLinkUp(gatt) }
            }
        }

        // GATT-data: an indication from the peripheral → reassemble Hop frames.
        @Deprecated("compat with API < 33")
        override fun onCharacteristicChanged(
            gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic,
        ) {
            if (characteristic.uuid == DATA_CHAR_UUID) {
                val data = characteristic.value ?: return
                val id = gattLinkGatt.entries.firstOrNull { it.value === gatt }?.key ?: return
                core.post { gattLinks[id]?.onChunkReceived(data) }
            }
        }

        // GATT-data: our write-with-response was acked → the link can send its next chunk.
        @Deprecated("compat with API < 33")
        override fun onCharacteristicWrite(
            gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int,
        ) {
            if (characteristic.uuid == DATA_CHAR_UUID) {
                val id = gattLinkGatt.entries.firstOrNull { it.value === gatt }?.key ?: return
                core.post { gattLinks[id]?.onChunkSent() }
            }
        }
    }

    /// Central GATT-data fallback step 1: subscribe to the peer's DATA characteristic (enable
    /// indications). The link comes up in onDescriptorWrite → gattDataLinkUp.
    private fun startCentralGattData(gatt: BluetoothGatt) {
        val ch = gatt.getService(SERVICE_UUID)?.getCharacteristic(DATA_CHAR_UUID) ?: run {
            runCatching { gatt.close() }; core.post { dialFailed(gatt.device.address) }; return
        }
        runCatching { gatt.setCharacteristicNotification(ch, true) }
        val cccd = ch.getDescriptor(CCCD_UUID) ?: run {
            runCatching { gatt.close() }; core.post { dialFailed(gatt.device.address) }; return
        }
        @Suppress("DEPRECATION")
        cccd.value = BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
        @Suppress("DEPRECATION")
        if (gatt.writeDescriptor(cccd) != true) { runCatching { gatt.close() }; core.post { dialFailed(gatt.device.address) } }
    }

    /// Central GATT-data step 2: subscription confirmed → register the link (Noise initiator) and
    /// wire its sends to write-with-response. node.connected queues m1, which pump() ships.
    private fun gattDataLinkUp(gatt: BluetoothGatt) {
        if (gattLinkGatt.values.any { it === gatt }) return   // already up
        val device = gatt.device
        val ch = gatt.getService(SERVICE_UUID)?.getCharacteristic(DATA_CHAR_UUID) ?: return
        val id = nextGattLinkId++
        val link = GattDataLink(
            id = id,
            usablePayload = { (gattMtu[device.address] ?: 23) - 3 },
            sendChunk = { chunk ->
                ch.value = chunk
                ch.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT   // write-with-response (acked)
                @Suppress("DEPRECATION")
                gatt.writeCharacteristic(ch) == true
            },
            onBytes = { lid, data -> node.received(lid, data); pump() },
            onClose = { lid -> core.post { closeGattLink(lid) } },
        )
        gattLinks[id] = link
        gattLinkGatt[id] = gatt
        connecting.add(device.address)
        node.connected(id, true)   // central = Noise initiator
        android.util.Log.i("HOPLOG", "GATT-data link UP id=$id initiator=true remote=${device.address}")
        dialSucceeded(device.address)
        pump()
    }

    companion object {
        val SERVICE_UUID: UUID = UUID.fromString("F0900000-0000-4000-8000-000000000000")
        val PSM_CHAR_UUID: UUID = UUID.fromString("F0900001-0000-4000-8000-000000000000")
        // GATT-data fallback (cross-platform, when L2CAP can't open): central WRITEs frames to this
        // characteristic, peripheral INDICATEs frames back. Both acked → reliable, ordered.
        val DATA_CHAR_UUID: UUID = UUID.fromString("F0900002-0000-4000-8000-000000000000")
        val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
        const val CHANNEL_ID = "hop.messages"
        const val PRESENCE_SERVICE = "presence"
        const val PRESENCE_TTL_MS: UInt = 600_000u
        const val DEFAULT_RELAY = "wss://relay.hopme.sh/"
        const val GATT_LIVENESS_MS = 20_000L  // reap a GATT-data link silent this long (keepalives are 1s)
        const val SCAN_WINDOW_MS = 5_000L   // central scans in short bursts…
        const val SCAN_IDLE_MS = 15_000L    // …then idles so the radio stays mostly in peripheral mode
        const val MAX_DIALS_IN_FLIGHT = 2   // gentle central: at most this many outbound connects at once
        const val DIAL_TIMEOUT_MS = 15_000L // a dial that hasn't linked by now is stuck → drop it
        const val DIAL_BACKOFF_MIN_MS = 8_000L    // first backoff after a failed/dropped dial
        const val DIAL_BACKOFF_MAX_MS = 120_000L  // ceiling (a chronically unreachable peer)
        const val HOP_MFG_ID = 0xFFFF       // BLE manufacturer ID (reserved/test) carrying our L2CAP PSM
        const val APPLE_MFG_ID = 0x004C     // Apple company ID — required for the iBeacon iOS recognizes
        // iBeacon proximity UUID the iOS app monitors (HopBearer.beaconUUID). Advertising it from
        // Android wakes a backgrounded/killed iPhone via iOS region monitoring (DESIGN.md §22).
        val HOP_BEACON_UUID: UUID = UUID.fromString("7ED7BEAC-3C2A-4F19-9B8E-1A2B3C4D5E6F")
        const val LAN_SERVICE = "_hoplan._tcp"   // Bonjour/NSD type, matches iOS HopBearer.lanServiceType
        const val LAN_PORT = 47474          // fixed TCP port: NSD advertises it; Wi-Fi Direct GO listens here
        /// Shared app secret for Hop Debug — all our demo devices use it so they interoperate.
        /// A different app (different secret) can't see or join these channels (DESIGN.md §32).
        val APP_SECRET = ByteArray(32) { 0x48 } // "H" ×32 — dev build only (matches iOS)

        @Volatile private var inst: HopBearer? = null

        /// One shared instance, owned by the foreground service and observed by the UI.
        /// Configure-once: the first caller's HopConfig wins; later callers get that same instance.
        /// The host (MainActivity) configures explicitly; a bare service restart falls back to
        /// HopConfig.default(context), preserving the prior behavior.
        fun shared(context: Context, config: HopConfig): HopBearer =
            inst ?: synchronized(this) {
                inst ?: HopBearer(context.applicationContext, config).also { inst = it }
            }

        fun shared(context: Context): HopBearer =
            inst ?: shared(context, HopConfig.default(context.applicationContext))

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
