package net.waldrip.hop.demo

import android.Manifest
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.animation.core.*
import androidx.compose.ui.draw.clip
import kotlinx.coroutines.delay
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import com.google.zxing.BarcodeFormat
import com.google.zxing.qrcode.QRCodeWriter
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import java.io.ByteArrayInputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class MainActivity : ComponentActivity() {
    private lateinit var bearer: HopBearer

    private val permissions: Array<String>
        get() {
            val perms = mutableListOf<String>()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                perms += listOf(
                    Manifest.permission.BLUETOOTH_SCAN,
                    Manifest.permission.BLUETOOTH_ADVERTISE,
                    Manifest.permission.BLUETOOTH_CONNECT,
                )
            } else {
                perms += Manifest.permission.ACCESS_FINE_LOCATION
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                perms += Manifest.permission.POST_NOTIFICATIONS
                perms += Manifest.permission.NEARBY_WIFI_DEVICES   // Wi-Fi Direct discovery (13+)
            } else {
                // Wi-Fi Direct service discovery needs fine location through Android 12L.
                perms += Manifest.permission.ACCESS_FINE_LOCATION
            }
            return perms.distinct().toTypedArray()
        }

    private val requestPerms =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
            // BLE perms are required; notification + Wi-Fi-nearby perms are best-effort.
            val optional = setOf(Manifest.permission.POST_NOTIFICATIONS,
                Manifest.permission.NEARBY_WIFI_DEVICES)
            val bleOk = result.filterKeys { it !in optional }.values.all { it }
            if (bleOk) HopService.start(this) // service starts the shared bearer
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        bearer = HopBearer.shared(this)
        setContent { MaterialTheme { HopApp(bearer) } }
        requestPerms.launch(permissions)
    }

    override fun onResume() { super.onResume(); bearer.setForeground(true) }
    override fun onPause() { super.onPause(); bearer.setForeground(false) }
}

private fun platformLabel(p: String): String = when (p) {
    "ios" -> "iOS"; "android" -> "Android"; else -> p
}

/// A glyph + label per direct transport, mirroring the iOS SF Symbols. "LAN" is a shared-network
/// Wi-Fi link (mDNS); "P2P" is peer-to-peer Wi-Fi (Wi-Fi Direct / AWDL) with no router.
private fun transportSymbol(tag: String): String = when (tag) {
    "BT" -> "🔷 BT"
    "LAN" -> "🌐 LAN"
    "P2P" -> "📡 P2P"
    "Relay" -> "☁️ Relay"
    else -> tag
}

/// Encode text (our "<base58>|<name>") to a QR bitmap via zxing core.
private fun makeQrBitmap(text: String, size: Int = 600): android.graphics.Bitmap {
    val bits = QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, size, size)
    val bmp = android.graphics.Bitmap.createBitmap(size, size, android.graphics.Bitmap.Config.RGB_565)
    for (x in 0 until size) for (y in 0 until size)
        bmp.setPixel(x, y, if (bits[x, y]) android.graphics.Color.BLACK else android.graphics.Color.WHITE)
    return bmp
}

/// One-line metadata under a chat bubble (mirrors the iOS app).
/// Decode + downscale an image to a modest JPEG so the mesh transfer stays reasonable —
/// the carrier path chunks it (§20), but smaller means fewer chunks and faster across wakes.
private fun jpegDownscale(raw: ByteArray, maxDim: Int = 1280, quality: Int = 80): ByteArray {
    val src = android.graphics.BitmapFactory.decodeByteArray(raw, 0, raw.size) ?: return raw
    val longest = maxOf(src.width, src.height).toFloat()
    val scale = longest / maxDim
    val bmp = if (scale > 1f) {
        android.graphics.Bitmap.createScaledBitmap(
            src, (src.width / scale).toInt(), (src.height / scale).toInt(), true
        )
    } else src
    val out = java.io.ByteArrayOutputStream()
    bmp.compress(android.graphics.Bitmap.CompressFormat.JPEG, quality, out)
    return out.toByteArray()
}

private fun messageMeta(m: HopBearer.Message): String {
    if (m.incoming) {
        var s = HopBearer.hopsLabel(m.hops)
        m.latencyMs?.let { s += ", ${HopBearer.compactDuration(it)}" }
        if (m.trace.isNotEmpty()) s += "  ·  via ${m.trace.joinToString(" → ")}"
        return s
    }
    if (m.delivered && m.deliveredAt != null) {
        val dur = HopBearer.compactDuration((m.deliveredAt - m.sentAt).coerceAtLeast(0).toULong())
        return "Delivered, ${HopBearer.hopsLabel(m.deliveryHops)}, $dur"
    }
    if (m.failed) return "Not sent"
    // relayed == 0 is rendered by SendingIndicator (pulsing + live timer), not this string.
    return "Sent · ${m.relayed} peer${if (m.relayed == 1u) "" else "s"}"
}

/// In-flight status for a message not yet handed to any peer: a pulsing dot + a live "Awaiting
/// peers · Ns" timer, so it reads as "working, holding for a peer" instead of a static, alarming
/// "Sending…". Flips to the peer hand-off count (messageMeta) once relayed > 0.
@Composable
private fun SendingIndicator(sentAt: Long, peersReachable: Boolean) {
    var elapsed by remember(sentAt) { mutableStateOf(0L) }
    LaunchedEffect(sentAt) {
        while (true) {
            elapsed = (System.currentTimeMillis() - sentAt).coerceAtLeast(0L) / 1000
            delay(1000)
        }
    }
    // Pulse driven by the 1-second tick (alternating alpha, smoothly faded) — NOT a continuous
    // 60fps infiniteTransition. The latter kept Compose from ever going idle, which blocked the
    // soft keyboard from opening in the chat composer. This settles between ticks.
    val alpha by animateFloatAsState(if (elapsed % 2 == 0L) 1f else 0.35f, label = "pulse")
    // With peers around, the holdup is the recipient's forward-secret session, not peer availability.
    val label = if (peersReachable) "Securing" else "Awaiting peers"
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(6.dp).clip(CircleShape).background(Color(0xFFFF9500).copy(alpha = alpha)))
        Spacer(Modifier.width(5.dp))
        Text("$label · ${elapsed}s", style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
fun HopApp(bearer: HopBearer) {
    var selected by remember { mutableStateOf<HopBearer.Peer?>(null) }
    val peer = selected
    if (peer != null) { ChatScreen(bearer, peer) { selected = null }; return }
    var tab by remember { mutableStateOf(0) }
    Scaffold(bottomBar = {
        NavigationBar {
            NavigationBarItem(selected = tab == 0, onClick = { tab = 0 },
                icon = { Text("💬") }, label = { Text("Chats") })
            NavigationBarItem(selected = tab == 1, onClick = { tab = 1 },
                icon = { Text("📡") }, label = { Text("Channels") })
            NavigationBarItem(selected = tab == 2, onClick = { tab = 2 },
                icon = { Text("🌐") }, label = { Text("Web") })
            NavigationBarItem(selected = tab == 3, onClick = { tab = 3 },
                icon = { Text("⚙️") }, label = { Text("Status") })
        }
    }) { pad ->
        Box(Modifier.padding(pad)) {
            when (tab) {
                0 -> ChatsScreen(bearer) { selected = it }
                1 -> ChannelsScreen(bearer)
                2 -> WebScreen(bearer)
                else -> StatusScreen(bearer)
            }
        }
    }
}

/// Tab 4: Status — device info + cloud relay (shared IA with iOS).
@Composable
fun StatusScreen(bearer: HopBearer) {
    var relayField by remember { mutableStateOf("") }
    LazyColumn(Modifier.fillMaxSize().padding(16.dp)) {
        item {
            Text("Status", style = MaterialTheme.typography.headlineSmall)
            Spacer(Modifier.height(12.dp))
            Text("This device", style = MaterialTheme.typography.titleMedium)
            Text("Name: ${bearer.myName.value}")
            Text("Address: ${bearer.myAddress.value}", style = MaterialTheme.typography.bodySmall)
            Text(bearer.status.value, style = MaterialTheme.typography.bodySmall)
            Spacer(Modifier.height(16.dp))

            // Privacy + QR identity exchange
            Text("Privacy", style = MaterialTheme.typography.titleMedium)
            var showQr by remember { mutableStateOf(false) }
            val scanLauncher = rememberLauncherForActivityResult(ScanContract()) { result ->
                val payload = result.contents ?: return@rememberLauncherForActivityResult
                val body = payload.removePrefix("hop:")
                val parts = body.split("|", limit = 2)
                parts.getOrNull(0)?.let { bearer.addContact(parts.getOrNull(1) ?: "", it) }
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Switch(checked = bearer.privateMode.value, onCheckedChange = { bearer.setPrivateMode(it) })
                Spacer(Modifier.width(8.dp))
                Text(
                    if (bearer.privateMode.value) "Private — not broadcasting your name. Reachable via your QR; still relays for all."
                    else "Discoverable — broadcasting your name to nearby devices.",
                    style = MaterialTheme.typography.bodySmall,
                )
            }
            Spacer(Modifier.height(8.dp))
            Row {
                Button(onClick = { showQr = true }) { Text("My QR") }
                Spacer(Modifier.width(8.dp))
                OutlinedButton(onClick = {
                    scanLauncher.launch(ScanOptions().setOrientationLocked(false)
                        .setBeepEnabled(false).setPrompt("Scan a Hop QR"))
                }) { Text("Scan to add") }
            }
            if (showQr) {
                AlertDialog(
                    onDismissRequest = { showQr = false },
                    confirmButton = { TextButton(onClick = { showQr = false }) { Text("Done") } },
                    title = { Text("My Hop code") },
                    text = {
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            val bmp = remember(bearer.myAddress.value, bearer.myName.value) {
                                runCatching { makeQrBitmap("${bearer.myAddress.value}|${bearer.myName.value}") }.getOrNull()
                            }
                            bmp?.let { Image(it.asImageBitmap(), "qr", Modifier.size(240.dp)) }
                            Spacer(Modifier.height(8.dp))
                            Text(bearer.myName.value)
                            Text(bearer.myAddress.value, style = MaterialTheme.typography.bodySmall)
                            Text("Have someone scan to add you — works in private mode.",
                                style = MaterialTheme.typography.bodySmall)
                        }
                    },
                )
            }
            Spacer(Modifier.height(16.dp))
            Text("Cloud relay (backbone)", style = MaterialTheme.typography.titleMedium)
            Row(verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(relayField, { relayField = it }, singleLine = true,
                    label = { Text("host:port or wss://relay.hopme.sh/") }, modifier = Modifier.weight(1f))
                Spacer(Modifier.width(8.dp))
                Button(onClick = { val t = relayField.trim(); if (t.isNotEmpty()) bearer.setPinnedRelay(t) }) {
                    Text("Pin")
                }
            }
            Text("Relay: ${bearer.relayStatus.value}", style = MaterialTheme.typography.bodySmall)
            val pinned = bearer.pinnedRelay.value
            if (pinned != null) {
                Text("Pinned: $pinned", style = MaterialTheme.typography.bodySmall)
                TextButton(onClick = { bearer.setPinnedRelay(null); relayField = "" }) {
                    Text("Unpin (use anycast default)")
                }
            } else {
                Text("Anycast (default). A device uses one relay at a time — pin a direct address to test a specific relay.",
                    style = MaterialTheme.typography.bodySmall)
            }
            Spacer(Modifier.height(16.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Relay queue (${bearer.queue.size})", style = MaterialTheme.typography.titleMedium)
                Spacer(Modifier.weight(1f))
                if (bearer.queue.isNotEmpty()) TextButton(onClick = { bearer.clearQueue() }) { Text("Clear") }
            }
        }
        items(bearer.queue) { q ->
            Text((if (q.own) "📌 yours → " else "↔ relay → ") + "${q.to}  ·  p${q.priority} · ${q.hops}h",
                style = MaterialTheme.typography.bodySmall)
        }
        item {
            Spacer(Modifier.height(16.dp))
            Text("Service log", style = MaterialTheme.typography.titleMedium)
            if (bearer.serviceLog.isEmpty()) Text("none", style = MaterialTheme.typography.bodySmall)
        }
        items(bearer.serviceLog) { line -> Text(line, style = MaterialTheme.typography.bodySmall) }
    }
}

/// hps:// pub/sub (DESIGN.md §32): host a channel/service, subscribe by host+path, publish,
/// and read sender-verified messages — Android parity with the iOS HpsView.
@Composable
fun ChannelsScreen(bearer: HopBearer) {
    var openId by remember { mutableStateOf<String?>(null) }
    var showAdd by remember { mutableStateOf(false) }

    val open = openId
    val topic = bearer.hpsTopics.firstOrNull { it.id == open }
    if (open != null && topic != null) {
        ChannelScreen(bearer, topic) { openId = null }
        return
    }

    if (showAdd) {
        HpsAddPanel(bearer, onDone = { showAdd = false })
        return
    }

    LazyColumn(Modifier.fillMaxSize().padding(16.dp)) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Channels", style = MaterialTheme.typography.headlineSmall)
                Spacer(Modifier.weight(1f))
                Button(onClick = { showAdd = true }) { Text("＋ Add") }
            }
            Spacer(Modifier.height(8.dp))
        }
        if (bearer.hpsInvites.isNotEmpty()) {
            item { Text("Invites", style = MaterialTheme.typography.titleMedium) }
            items(bearer.hpsInvites) { inv ->
                ListItem(
                    headlineContent = { Text("✉ " + inv.path) },
                    supportingContent = { Text("from " + bearer.displayName(inv.host)) },
                    trailingContent = {
                        Row {
                            TextButton(onClick = { bearer.hpsAcceptInvite(inv) }) { Text("Accept") }
                            TextButton(onClick = { bearer.hpsDeclineInvite(inv) }) { Text("Decline") }
                        }
                    },
                )
            }
        }
        item { Spacer(Modifier.height(8.dp)); Text("Channels & services", style = MaterialTheme.typography.titleMedium) }
        if (bearer.hpsTopics.isEmpty()) {
            item { Text("None yet. Tap ＋ Add to host, subscribe, or browse.", style = MaterialTheme.typography.bodySmall) }
        }
        items(bearer.hpsTopics) { t ->
            val unread = bearer.hpsUnread[t.id] ?: 0
            ListItem(
                headlineContent = { Text((if (t.channel) "💬 " else "📣 ") + t.path) },
                supportingContent = { Text((if (t.hosting) "hosting · " else "subscribed · ") + HopBearer.shortHex(t.host)) },
                trailingContent = { if (unread > 0) Text("$unread", color = MaterialTheme.colorScheme.error) },
                modifier = Modifier.clickable { openId = t.id },
            )
        }
    }
}

@Composable
fun ChannelScreen(bearer: HopBearer, topic: HopBearer.HpsTopic, onBack: () -> Unit) {
    var draft by remember { mutableStateOf("") }
    var showInfo by remember { mutableStateOf(false) }
    DisposableEffect(topic.id) {
        bearer.openTopic(topic.id)
        onDispose { bearer.closeTopic() }
    }
    if (showInfo) { ChannelInfoPanel(bearer, topic, onDone = { showInfo = false }); return }

    Column(Modifier.fillMaxSize()) {
        Row(Modifier.padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = onBack) { Text("‹ Back") }
            Text((if (topic.channel) "💬 " else "📣 ") + topic.path, style = MaterialTheme.typography.titleLarge)
            Spacer(Modifier.weight(1f))
            TextButton(onClick = { showInfo = true }) { Text("ⓘ") }
        }
        val msgs = bearer.hpsThreads[topic.id] ?: emptyList<HopBearer.HpsMsg>()
        LazyColumn(Modifier.weight(1f).padding(horizontal = 12.dp)) {
            items(msgs) { m ->
                val mine = m.sender.contentEquals(bearer.node.address())
                Column(Modifier.fillMaxWidth().padding(vertical = 4.dp),
                    horizontalAlignment = if (mine) Alignment.End else Alignment.Start) {
                    Text(bearer.displayName(m.sender), style = MaterialTheme.typography.bodySmall)
                    Text(m.text)
                }
            }
        }
        if (topic.writable) {
            Row(Modifier.padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(draft, { draft = it }, singleLine = true,
                    label = { Text("Message #${topic.path}") }, modifier = Modifier.weight(1f))
                Spacer(Modifier.width(8.dp))
                Button(onClick = { bearer.hpsPublish(topic, draft.trim()); draft = "" },
                    enabled = draft.isNotBlank()) { Text("Send") }
            }
        } else {
            Text("Read-only (only the owner broadcasts)",
                style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(8.dp))
        }
    }
}

@Composable
fun ChannelInfoPanel(bearer: HopBearer, topic: HopBearer.HpsTopic, onDone: () -> Unit) {
    LazyColumn(Modifier.fillMaxSize().padding(16.dp)) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(topic.path, style = MaterialTheme.typography.headlineSmall)
                Spacer(Modifier.weight(1f)); TextButton(onClick = onDone) { Text("Done") }
            }
            Text((if (topic.channel) "Channel" else "Service") + " · " +
                 (if (topic.hosting) "hosting" else "subscribed") + " · " + HopBearer.shortHex(topic.host),
                 style = MaterialTheme.typography.bodySmall)
            Spacer(Modifier.height(12.dp))
        }
        if (topic.hosting) {
            item {
                Text("Reach: ${bearer.hpsReach(topic)} members", style = MaterialTheme.typography.titleMedium)
                Spacer(Modifier.height(8.dp)); Text("Invite a contact", style = MaterialTheme.typography.titleMedium)
            }
            items(bearer.contactList) { p ->
                ListItem(headlineContent = { Text(p.name) },
                    trailingContent = { TextButton(onClick = { bearer.hpsInvite(topic, p.address) }) { Text("Invite") } })
            }
            val pending = bearer.hpsPending(topic)
            if (pending.isNotEmpty()) {
                item { Spacer(Modifier.height(8.dp)); Text("Join requests", style = MaterialTheme.typography.titleMedium) }
                items(pending) { who ->
                    ListItem(headlineContent = { Text(bearer.displayName(who)) },
                        trailingContent = {
                            Row {
                                TextButton(onClick = { bearer.hpsApprove(topic, who) }) { Text("Approve") }
                                TextButton(onClick = { bearer.hpsDeny(topic, who) }) { Text("Deny") }
                            }
                        })
                }
            }
            val members = bearer.hpsMembers(topic)
            if (members.isNotEmpty()) {
                item { Spacer(Modifier.height(8.dp)); Text("Members", style = MaterialTheme.typography.titleMedium) }
                items(members) { who ->
                    ListItem(headlineContent = { Text(bearer.displayName(who)) },
                        trailingContent = { TextButton(onClick = { bearer.hpsRekey(topic, listOf(who)) }) { Text("Remove") } })
                }
                item { TextButton(onClick = { bearer.hpsRekey(topic) }) { Text("Rotate keys (no removal)") } }
            }
        } else {
            item { TextButton(onClick = { bearer.hpsLeave(topic); onDone() }) { Text("Leave channel") } }
        }
    }
}

@Composable
fun HpsAddPanel(bearer: HopBearer, onDone: () -> Unit) {
    var mode by remember { mutableStateOf(0) }
    var newPath by remember { mutableStateOf("") }
    var isChannel by remember { mutableStateOf(true) }
    var access by remember { mutableStateOf(uniffi.hop_ffi.HpsAccess.OPEN) }
    var discoverable by remember { mutableStateOf(false) }
    var subHost by remember { mutableStateOf("") }
    var subPath by remember { mutableStateOf("") }
    var found by remember { mutableStateOf(listOf<uniffi.hop_ffi.HpsTopicInfo>()) }

    LazyColumn(Modifier.fillMaxSize().padding(16.dp)) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Add channel", style = MaterialTheme.typography.headlineSmall)
                Spacer(Modifier.weight(1f)); TextButton(onClick = onDone) { Text("Cancel") }
            }
            Row {
                FilterChip(mode == 0, { mode = 0 }, label = { Text("Host") })
                Spacer(Modifier.width(6.dp))
                FilterChip(mode == 1, { mode = 1 }, label = { Text("Subscribe") })
                Spacer(Modifier.width(6.dp))
                FilterChip(mode == 2, { mode = 2; found = bearer.hpsBrowse() }, label = { Text("Browse") })
            }
            Spacer(Modifier.height(12.dp))
            when (mode) {
                0 -> Column {
                    OutlinedTextField(newPath, { newPath = it }, singleLine = true,
                        label = { Text("path (e.g. lobby)") }, modifier = Modifier.fillMaxWidth())
                    Row {
                        FilterChip(isChannel, { isChannel = true }, label = { Text("Channel") })
                        Spacer(Modifier.width(8.dp))
                        FilterChip(!isChannel, { isChannel = false }, label = { Text("Service") })
                    }
                    Text("Access", style = MaterialTheme.typography.bodySmall)
                    Row {
                        FilterChip(access == uniffi.hop_ffi.HpsAccess.OPEN, { access = uniffi.hop_ffi.HpsAccess.OPEN }, label = { Text("Open") })
                        Spacer(Modifier.width(6.dp))
                        FilterChip(access == uniffi.hop_ffi.HpsAccess.REQUEST_TO_JOIN, { access = uniffi.hop_ffi.HpsAccess.REQUEST_TO_JOIN }, label = { Text("Request") })
                        Spacer(Modifier.width(6.dp))
                        FilterChip(access == uniffi.hop_ffi.HpsAccess.INVITE, { access = uniffi.hop_ffi.HpsAccess.INVITE }, label = { Text("Invite") })
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Checkbox(discoverable, { discoverable = it }); Text("Discoverable nearby")
                    }
                    Button(onClick = { bearer.hpsRegister(newPath, isChannel, access, discoverable); onDone() },
                        enabled = newPath.isNotBlank()) { Text("Create") }
                }
                1 -> Column {
                    OutlinedTextField(subHost, { subHost = it }, singleLine = true,
                        label = { Text("host address (base58)") }, modifier = Modifier.fillMaxWidth())
                    OutlinedTextField(subPath, { subPath = it }, singleLine = true,
                        label = { Text("path") }, modifier = Modifier.fillMaxWidth())
                    Button(onClick = { bearer.hpsSubscribe(subHost, subPath); onDone() },
                        enabled = subHost.isNotBlank() && subPath.isNotBlank()) { Text("Subscribe") }
                }
                else -> Column {
                    if (found.isEmpty()) Text("None found yet", style = MaterialTheme.typography.bodySmall)
                    found.forEach { t ->
                        ListItem(
                            headlineContent = { Text(t.path) },
                            supportingContent = { Text((if (t.kind == uniffi.hop_ffi.HpsKind.CHANNEL) "channel" else "service") + " · " + HopBearer.shortHex(t.host)) },
                            trailingContent = {
                                TextButton(onClick = { bearer.hpsJoin(t); onDone() }) {
                                    Text(if (t.access == uniffi.hop_ffi.HpsAccess.OPEN) "Join" else "Request")
                                }
                            },
                        )
                    }
                    TextButton(onClick = { found = bearer.hpsBrowse() }) { Text("Refresh") }
                }
            }
        }
    }
}

/// hops:// (DESIGN.md §30): resolve a domain via HNS and fetch over the mesh; show the result
/// and the live HNS cache. Android parity with the iOS hops:// section.
@Composable
fun WebScreen(bearer: HopBearer) {
    var field by remember { mutableStateOf("example.hopme.sh") }
    var browseUrl by remember { mutableStateOf<String?>(null) }
    val url = browseUrl
    if (url != null) { HopBrowser(bearer, url) { browseUrl = null }; return }
    LazyColumn(Modifier.fillMaxSize().padding(16.dp)) {
        item {
            Text("hops://", style = MaterialTheme.typography.headlineSmall)
            Spacer(Modifier.height(8.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(field, { field = it }, singleLine = true,
                    label = { Text("domain or hops:// url") }, modifier = Modifier.weight(1f))
                Spacer(Modifier.width(8.dp))
                Button(onClick = { if (field.isNotBlank()) bearer.openHops(field) }) { Text("Fetch") }
            }
            TextButton(onClick = { if (field.isNotBlank()) browseUrl = field }) { Text("🌐 Open in browser") }
            Spacer(Modifier.height(12.dp))
        }
        items(bearer.hopsResults.entries.toList()) { (domain, text) ->
            Column(Modifier.padding(vertical = 6.dp)) {
                Text(domain, style = MaterialTheme.typography.bodySmall)
                Text(text)
            }
        }
        item {
            Spacer(Modifier.height(16.dp))
            Text("HNS cache (${bearer.hnsCache.size})", style = MaterialTheme.typography.titleMedium)
        }
        items(bearer.hnsCache) { e ->
            ListItem(
                headlineContent = { Text(e.domain) },
                supportingContent = {
                    Text(if (e.address.isEmpty()) "no record (negative)" else HopBearer.shortHex(e.address))
                },
                trailingContent = { Text("TTL ${e.ttlSecs}s", style = MaterialTheme.typography.bodySmall) },
            )
        }
    }
}

@Composable
fun ChatsScreen(bearer: HopBearer, onPick: (HopBearer.Peer) -> Unit) {
    // "Direct" = reachable without the cloud relay: either a live local radio link (BLE / Wi-Fi
    // P2P), OR a ≤1-hop (direct-neighbour) advert. The link signal catches a peer whose advert
    // arrived via a longer relay path; the hop signal is robust to links churning in/out of
    // peerLinks (otherwise direct peers flicker to "mesh" between blips).
    // Direct = a 1-hop neighbour. A live BT/Wi-Fi link is forced to 1 hop in refresh(), so this
    // single rule covers both live links and direct adverts — a 2-hop peer is never "direct".
    fun isDirect(p: HopBearer.Peer): Boolean = p.hops <= 1u
    val direct = bearer.peers.filter { isDirect(it) }
    val mesh = bearer.peers.filter { !isDirect(it) }
    val offline = bearer.seen   // address book entries not currently reachable
    Column(Modifier.fillMaxSize().padding(16.dp)) {
        Text("Chats", style = MaterialTheme.typography.headlineMedium)
        Spacer(Modifier.height(8.dp))
        if (bearer.peers.isEmpty() && offline.isEmpty()) Text("looking for others…")
        LazyColumn {
            item { Text("Nearby (direct)", style = MaterialTheme.typography.titleMedium) }
            if (direct.isEmpty()) item { Text("none", style = MaterialTheme.typography.bodySmall) }
            items(direct) { p -> PeerRow(bearer, p, onPick) }
            item { Spacer(Modifier.height(12.dp)); Text("In the mesh (relayed)", style = MaterialTheme.typography.titleMedium) }
            if (mesh.isEmpty()) item { Text("none", style = MaterialTheme.typography.bodySmall) }
            items(mesh) { p -> PeerRow(bearer, p, onPick) }
            if (offline.isNotEmpty()) {
                item { Spacer(Modifier.height(12.dp)); Text("Conversations & seen (offline)", style = MaterialTheme.typography.titleMedium) }
                items(offline) { p -> PeerRow(bearer, p, onPick) }
            }
        }
    }
}

@Composable
private fun PeerRow(bearer: HopBearer, p: HopBearer.Peer, onPick: (HopBearer.Peer) -> Unit) {
    val locked = bearer.secured.contains(p.address.toList())
    val transport = bearer.linkTransports[p.address.toList()]?.let { transportSymbol(it) }
    val subline = listOf(HopBearer.shortHex(p.address), platformLabel(p.platform), p.app)
        .filter { it.isNotEmpty() }.joinToString(" · ")
    ListItem(
        leadingContent = {
            Box(Modifier.size(8.dp).clip(CircleShape)
                .background(if (p.active) Color(0xFF34C759) else Color.Gray))
        },
        headlineContent = { Text(p.name + if (locked) "  🔒" else "") },
        supportingContent = { Text(subline) },
        trailingContent = {
            val isLive = bearer.peers.any { it.address.contentEquals(p.address) }
            Text(
                if (!isLive) "offline"
                else (transport?.let { "$it · " } ?: "") + HopBearer.hopsLabel(p.hops),
                style = MaterialTheme.typography.bodySmall,
            )
        },
        modifier = Modifier.clickable { onPick(p) },
    )
}

@Composable
fun ChatScreen(bearer: HopBearer, peer: HopBearer.Peer, onBack: () -> Unit) {
    var draft by remember { mutableStateOf("") }
    val attached = remember { mutableStateListOf<ByteArray>() } // staged images for one multipart send
    val thread = bearer.messages.filter { it.peer == peer.name }
    val context = LocalContext.current
    // Pick one OR MORE images, downscale to JPEG, and stage them; Send fires one multipart (§20).
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.GetMultipleContents()) { uris ->
        for (uri in uris) {
            runCatching {
                val raw = context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
                if (raw != null) attached.add(jpegDownscale(raw))
            }
        }
    }
    Column(Modifier.fillMaxSize().padding(16.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = onBack) { Text("‹ Back") }
            val locked = bearer.secured.contains(peer.address.toList())
            Text(peer.name + if (locked) "  🔒" else "", style = MaterialTheme.typography.titleLarge)
        }
        LazyColumn(Modifier.weight(1f)) {
            items(thread) { m ->
                Column(Modifier.padding(vertical = 4.dp)) {
                    val imgs = m.imageData?.let { listOf(it) } ?: m.images
                    for ((idx, img) in imgs.withIndex()) {
                        val bmp = remember(m.localId, idx) {
                            android.graphics.BitmapFactory.decodeByteArray(img, 0, img.size)
                        }
                        if (bmp != null) {
                            Image(bmp.asImageBitmap(), contentDescription = "photo",
                                modifier = Modifier.fillMaxWidth().heightIn(max = 240.dp))
                            Spacer(Modifier.height(4.dp))
                        }
                    }
                    if (m.text.isNotEmpty()) Text((if (m.incoming) "‹ " else "› ") + m.text)
                    if (m.failed && !m.incoming) {
                        Text("⟳ Not sent · tap to retry", color = MaterialTheme.colorScheme.error,
                            style = MaterialTheme.typography.bodySmall,
                            modifier = Modifier.clickable { bearer.retry(m, peer) })
                    } else if (!m.incoming && !m.delivered && m.relayed == 0u) {
                        // relayed==0 with peers around isn't "awaiting peers" — it's awaiting the
                        // forward-secret session with THIS recipient (require-ratchet). Only with no
                        // reachable peers is it genuinely awaiting peers.
                        SendingIndicator(m.sentAt, peersReachable = bearer.peers.isNotEmpty() || bearer.linkCount.intValue > 0)
                    } else {
                        Text(messageMeta(m), style = MaterialTheme.typography.bodySmall)
                    }
                }
            }
        }
        // Staged-image tray.
        if (attached.isNotEmpty()) {
            LazyRow(Modifier.padding(vertical = 4.dp)) {
                items(attached.size) { i ->
                    val bmp = remember(attached[i]) {
                        android.graphics.BitmapFactory.decodeByteArray(attached[i], 0, attached[i].size)
                    }
                    if (bmp != null) {
                        Box(Modifier.padding(end = 6.dp)) {
                            Image(bmp.asImageBitmap(), contentDescription = "staged",
                                modifier = Modifier.size(48.dp))
                            TextButton(onClick = { attached.removeAt(i) },
                                contentPadding = PaddingValues(0.dp),
                                modifier = Modifier.align(Alignment.TopEnd)) { Text("✕") }
                        }
                    }
                }
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(value = draft, onValueChange = { draft = it },
                modifier = Modifier.weight(1f), placeholder = { Text("Message ${peer.name}") })
            TextButton(onClick = { picker.launch("image/*") }) { Text("📷") }
            Button(onClick = {
                val t = draft.trim()
                if (attached.isNotEmpty()) {
                    bearer.sendMultipart(t, attached.toList(), peer); attached.clear(); draft = ""
                } else if (t.isNotEmpty()) {
                    bearer.send(t, peer); draft = ""
                }
            }) { Text("Send") }
        }
    }
}

/// A hops:// browser: a WebView whose requests are intercepted and served over the mesh
/// (DESIGN.md §30). shouldInterceptRequest runs off the UI thread, so it blocks on a latch
/// while the bearer resolves + fetches the resource over Hop, then returns it to the WebView.
@Composable
fun HopBrowser(bearer: HopBearer, start: String, onBack: () -> Unit) {
    var bar by remember { mutableStateOf(normalizeHops(start)) }
    var webRef by remember { mutableStateOf<WebView?>(null) }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = onBack) { Text("‹") }
            OutlinedTextField(bar, { bar = it }, singleLine = true, modifier = Modifier.weight(1f))
            TextButton(onClick = { webRef?.loadUrl(normalizeHops(bar)) }) { Text("Go") }
        }
        AndroidView(modifier = Modifier.fillMaxSize(), factory = { ctx ->
            WebView(ctx).apply {
                webRef = this
                settings.javaScriptEnabled = true
                settings.domStorageEnabled = true
                webViewClient = object : WebViewClient() {
                    override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
                        if (request.url.scheme != "hops") return null
                        val latch = CountDownLatch(1)
                        var status = 504; var ctype = "text/plain; charset=utf-8"; var body = ByteArray(0)
                        bearer.hopsFetch(request.url.toString()) { s, c, b ->
                            status = s; ctype = c; body = b; latch.countDown()
                        }
                        if (!latch.await(30, TimeUnit.SECONDS)) {
                            body = "timed out".toByteArray(); status = 504
                        }
                        val mime = ctype.substringBefore(';').trim().ifEmpty { "text/plain" }
                        val enc = ctype.substringAfter("charset=", "utf-8").trim()
                        return WebResourceResponse(mime, enc, status, statusText(status), emptyMap(),
                            ByteArrayInputStream(body))
                    }
                }
                loadUrl(normalizeHops(start))
            }
        })
    }
}

private fun normalizeHops(s: String): String {
    val t = s.trim()
    return if (t.startsWith("hops://")) t else "hops://" + t.removePrefix("https://").removePrefix("http://")
}

private fun statusText(code: Int): String = when (code) {
    200 -> "OK"; 404 -> "Not Found"; 502 -> "Bad Gateway"; 503 -> "Unavailable"; 504 -> "Timeout"
    else -> "Status"
}
