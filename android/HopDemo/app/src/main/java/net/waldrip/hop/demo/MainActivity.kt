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
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
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
            }
            return perms.toTypedArray()
        }

    private val requestPerms =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
            // BLE perms are required; the notification perm is best-effort.
            val bleOk = result.filterKeys { it != Manifest.permission.POST_NOTIFICATIONS }
                .values.all { it }
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
        return s
    }
    if (m.delivered && m.deliveredAt != null) {
        val dur = HopBearer.compactDuration((m.deliveredAt - m.sentAt).coerceAtLeast(0).toULong())
        return "Delivered, ${HopBearer.hopsLabel(m.deliveryHops)}, $dur"
    }
    return if (m.relayed > 0u) "Sent, ${m.relayed} peer${if (m.relayed == 1u) "" else "s"}" else "Sending…"
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
                icon = { Text("👥") }, label = { Text("People") })
            NavigationBarItem(selected = tab == 1, onClick = { tab = 1 },
                icon = { Text("📡") }, label = { Text("Channels") })
            NavigationBarItem(selected = tab == 2, onClick = { tab = 2 },
                icon = { Text("🌐") }, label = { Text("Web") })
        }
    }) { pad ->
        Box(Modifier.padding(pad)) {
            when (tab) {
                0 -> PeopleScreen(bearer) { selected = it }
                1 -> ChannelsScreen(bearer)
                else -> WebScreen(bearer)
            }
        }
    }
}

/// hps:// pub/sub (DESIGN.md §32): host a channel/service, subscribe by host+path, publish,
/// and read sender-verified messages — Android parity with the iOS HpsView.
@Composable
fun ChannelsScreen(bearer: HopBearer) {
    var newPath by remember { mutableStateOf("") }
    var isChannel by remember { mutableStateOf(true) }
    var subHost by remember { mutableStateOf("") }
    var subPath by remember { mutableStateOf("") }
    var pubPath by remember { mutableStateOf("") }
    var pubText by remember { mutableStateOf("") }
    LazyColumn(Modifier.fillMaxSize().padding(16.dp)) {
        item {
            Text("hps:// pub/sub", style = MaterialTheme.typography.headlineSmall)
            Spacer(Modifier.height(8.dp))
            Text("Host a topic", style = MaterialTheme.typography.titleMedium)
            OutlinedTextField(newPath, { newPath = it }, singleLine = true,
                label = { Text("path (e.g. lobby)") }, modifier = Modifier.fillMaxWidth())
            Row(verticalAlignment = Alignment.CenterVertically) {
                FilterChip(isChannel, { isChannel = true }, label = { Text("Channel") })
                Spacer(Modifier.width(8.dp))
                FilterChip(!isChannel, { isChannel = false }, label = { Text("Service") })
                Spacer(Modifier.weight(1f))
                Button(onClick = { bearer.hpsRegister(newPath, isChannel); newPath = "" }) { Text("Register") }
            }
            Spacer(Modifier.height(12.dp))
            Text("Subscribe", style = MaterialTheme.typography.titleMedium)
            OutlinedTextField(subHost, { subHost = it }, singleLine = true,
                label = { Text("host address (base58)") }, modifier = Modifier.fillMaxWidth())
            Row(verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(subPath, { subPath = it }, singleLine = true,
                    label = { Text("path") }, modifier = Modifier.weight(1f))
                Spacer(Modifier.width(8.dp))
                Button(onClick = { bearer.hpsSubscribe(subHost, subPath); subPath = "" }) { Text("Sub") }
            }
            Spacer(Modifier.height(12.dp))
            Text("Topics", style = MaterialTheme.typography.titleMedium)
        }
        items(bearer.hpsTopics) { t ->
            ListItem(
                headlineContent = { Text((if (t.channel) "💬 " else "📣 ") + t.path) },
                supportingContent = { Text((if (t.hosting) "hosting · " else "subscribed · ") + HopBearer.shortHex(t.host)) },
                trailingContent = {
                    if (t.channel || t.hosting) TextButton(onClick = { pubPath = t.path }) { Text("✎") }
                },
            )
        }
        item {
            Spacer(Modifier.height(8.dp))
            Text("Publish" + if (pubPath.isNotEmpty()) " → $pubPath" else "", style = MaterialTheme.typography.titleMedium)
            if (pubPath.isEmpty()) Text("Tap ✎ on a writable topic", style = MaterialTheme.typography.bodySmall)
            else Row(verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(pubText, { pubText = it }, singleLine = true,
                    label = { Text("message") }, modifier = Modifier.weight(1f))
                Spacer(Modifier.width(8.dp))
                Button(onClick = { bearer.hpsPublish(pubPath, pubText); pubText = "" }) { Text("Send") }
            }
            Spacer(Modifier.height(12.dp))
            Text("Messages", style = MaterialTheme.typography.titleMedium)
            if (bearer.hpsInbox.isEmpty()) Text("none yet", style = MaterialTheme.typography.bodySmall)
        }
        items(bearer.hpsInbox) { m ->
            Column(Modifier.padding(vertical = 4.dp)) {
                Text("${m.path} · ${HopBearer.shortHex(m.sender)}", style = MaterialTheme.typography.bodySmall)
                Text(m.text)
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
fun PeopleScreen(bearer: HopBearer, onPick: (HopBearer.Peer) -> Unit) {
    Column(Modifier.fillMaxSize().padding(16.dp)) {
        Text("Hop", style = MaterialTheme.typography.headlineMedium)
        Text("You: ${bearer.myName.value}  ·  ${bearer.myAddress.value}",
            style = MaterialTheme.typography.bodySmall)
        Text(bearer.status.value, style = MaterialTheme.typography.bodySmall)

        Spacer(Modifier.height(12.dp))
        var relayField by remember { mutableStateOf("") }
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(
                value = relayField, onValueChange = { relayField = it },
                label = { Text("host:port or wss://relay.hopme.sh/") },
                singleLine = true, modifier = Modifier.weight(1f),
            )
            Spacer(Modifier.width(8.dp))
            Button(onClick = { val t = relayField.trim(); if (t.isNotEmpty()) bearer.connectRelay(t) }) {
                Text("Connect")
            }
        }
        Text("Cloud relay: ${bearer.relayStatus.value}", style = MaterialTheme.typography.bodySmall)

        Spacer(Modifier.height(16.dp))
        Text("People nearby (${bearer.peers.size})", style = MaterialTheme.typography.titleMedium)
        if (bearer.peers.isEmpty()) Text("looking for others…")
        LazyColumn {
            items(bearer.peers) { p ->
                val locked = bearer.secured.contains(p.address.toList())
                val subline = listOf(HopBearer.shortHex(p.address), platformLabel(p.platform), p.app)
                    .filter { it.isNotEmpty() }.joinToString(" · ")
                ListItem(
                    leadingContent = {
                        Box(Modifier.size(8.dp).clip(CircleShape)
                            .background(if (p.active) Color(0xFF34C759) else Color.Gray))
                    },
                    headlineContent = { Text(p.name + if (locked) "  🔒" else "") },
                    supportingContent = { Text(subline) },
                    trailingContent = { Text(HopBearer.hopsLabel(p.hops), style = MaterialTheme.typography.bodySmall) },
                    modifier = Modifier.clickable { onPick(p) },
                )
            }
        }
    }
}

@Composable
fun ChatScreen(bearer: HopBearer, peer: HopBearer.Peer, onBack: () -> Unit) {
    var draft by remember { mutableStateOf("") }
    val thread = bearer.messages.filter { it.peer == peer.name }
    val context = LocalContext.current
    // Pick an image, downscale to JPEG, and send it (carrier-chunked by core, §20).
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri ->
        if (uri != null) {
            runCatching {
                val raw = context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
                if (raw != null) bearer.sendImage(jpegDownscale(raw), peer)
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
                    val img = m.imageData
                    if (img != null) {
                        val bmp = remember(m.localId) {
                            android.graphics.BitmapFactory.decodeByteArray(img, 0, img.size)
                        }
                        Text(if (m.incoming) "‹ 📷" else "› 📷")
                        if (bmp != null) {
                            Image(bmp.asImageBitmap(), contentDescription = "photo",
                                modifier = Modifier.fillMaxWidth().heightIn(max = 240.dp))
                        }
                    } else {
                        Text((if (m.incoming) "‹ " else "› ") + m.text)
                    }
                    Text(messageMeta(m), style = MaterialTheme.typography.bodySmall)
                }
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(value = draft, onValueChange = { draft = it },
                modifier = Modifier.weight(1f), placeholder = { Text("Message ${peer.name}") })
            TextButton(onClick = { picker.launch("image/*") }) { Text("📷") }
            Button(onClick = {
                val t = draft.trim()
                if (t.isNotEmpty()) { bearer.send(t, peer); draft = "" }
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
