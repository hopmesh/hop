package sh.hopme.demo

import sh.hopme.driver.*
import android.Manifest
import android.content.Intent
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
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.imePadding
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
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.Dp
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

    /** Whether the required BLE permissions have been granted. Drives the gate below so a denial shows
     *  a recovery screen (android-10) instead of a silent, permanently-"starting…" dead-end. */
    private val bleGranted = mutableStateOf(false)
    /** True once the user has denied at least once and the OS will no longer show the system dialog
     *  ("Don't ask again" / permanent denial), leaving App Settings as the only recovery. */
    private val mustUseSettings = mutableStateOf(false)

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
            // F-37: Wi-Fi Direct is gone, so we no longer request NEARBY_WIFI_DEVICES (13+) or fine
            // location on 31-32 (which only Wi-Fi Direct needed — and denying it used to block start).
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                perms += Manifest.permission.POST_NOTIFICATIONS
            }
            return perms.distinct().toTypedArray()
        }

    /** The subset of [permissions] that are hard-required for the mesh (BLE); POST_NOTIFICATIONS is
     *  best-effort and never blocks start. */
    private val requiredPermissions: Array<String>
        get() = permissions.filter { it != Manifest.permission.POST_NOTIFICATIONS }.toTypedArray()

    private fun requiredGranted(): Boolean = requiredPermissions.all {
        checkSelfPermission(it) == android.content.pm.PackageManager.PERMISSION_GRANTED
    }

    private val requestPerms =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
            // BLE perms are required; the notification perm is best-effort.
            val optional = setOf(Manifest.permission.POST_NOTIFICATIONS)
            val bleOk = result.filterKeys { it !in optional }.values.all { it }
            bleGranted.value = bleOk
            if (bleOk) {
                mustUseSettings.value = false
                HopService.start(this) // service starts the shared bearer
            } else {
                // A denial that no longer shows the system dialog (shouldShowRationale == false AFTER a
                // request means "Don't ask again") can only be recovered from App Settings.
                mustUseSettings.value = requiredPermissions.none { shouldShowRequestPermissionRationale(it) }
            }
        }

    /** Ask for permissions again (the in-app "Grant" button on the denied screen). */
    private fun requestPermissionsNow() = requestPerms.launch(permissions)

    /** Deep-link to this app's system settings so a permanently-denied user can toggle permissions. */
    private fun openAppSettings() {
        startActivity(
            Intent(
                android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                android.net.Uri.fromParts("package", packageName, null),
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // android-r2-02: persist this app's relay choice to the ONE shared pref BEFORE building the
        // config, so an OS-driven START_STICKY service restart (which builds HopConfig.default with no
        // activity) resolves the SAME value instead of falling back to a different literal. Both paths
        // now read HopConfig.relaysEnabled(this); the singleton is configure-once, so this removes the
        // "which path minted it first" nondeterminism.
        HopConfig.persistRelaysEnabled(this, true)   // this build opts the relay ON
        // Configure the driver from the app's sources (identity, storage, backbone, presentation),
        // then hand off; the foreground service keeps the same shared instance running.
        val config = HopConfig(
            dbPath = java.io.File(filesDir, "hop.db").absolutePath,
            identitySecret = HopBearer.deviceSeed(this),
            appSecret = HopBearer.APP_SECRET,
            deviceName = HopConfig.deviceName(this),
            relayUrl = HopBearer.DEFAULT_RELAY,
            relaysEnabled = HopConfig.relaysEnabled(this),   // single source of truth (android-r2-02)
            notificationIcon = android.R.drawable.ic_dialog_email,
            // android-01: MUST match the sticky-service path (HopConfig.default sets this too). Without
            // it the activity opens hop.db PLAINTEXT while a START_STICKY service restart opens it keyed,
            // which used to quarantine-wipe all node state; SQLCipher-at-rest (F-25) also stayed OFF.
            dbKey = HopBearer.dbKey(this),
        )
        bearer = HopBearer.shared(this, config)
        // Edge-to-edge so Compose actually receives IME (keyboard) insets: Compose does NOT reliably
        // react to windowSoftInputMode=adjustResize on its own, so screens apply imePadding/
        // safeDrawingPadding to lift content above the keyboard + system bars.
        androidx.core.view.WindowCompat.setDecorFitsSystemWindows(window, false)
        bleGranted.value = requiredGranted()
        setContent {
            MaterialTheme {
                if (bleGranted.value) {
                    HopApp(bearer)
                } else {
                    PermissionGate(
                        mustUseSettings = mustUseSettings.value,
                        onGrant = { requestPermissionsNow() },
                        onOpenSettings = { openAppSettings() },
                    )
                }
            }
        }
        if (bleGranted.value) HopService.start(this) else requestPerms.launch(permissions)
        handleAutomationIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleAutomationIntent(intent)
    }

    /** Test/automation hook: `hopdemo://send?to=<base58>&text=<marker>` drives a send with NO UI taps,
     *  exercising the same bearer.send path the UI button uses.
     *
     *  android-r2-03: this is a silent send-as-user primitive. It is a NO-OP outside a debug build so a
     *  release APK never acts on the scheme (the exported filter is also debug-only via the manifest
     *  overlay). Mirrors iOS `handleAutomationURL` (`#if DEBUG`). */
    private fun handleAutomationIntent(intent: Intent?) {
        if (!BuildConfig.DEBUG) return   // release: ignore the automation scheme (android-r2-03)
        val d = intent?.data ?: return
        if (d.scheme == "hopdemo" && d.host == "send") {
            val to = d.getQueryParameter("to"); val text = d.getQueryParameter("text")
            if (!to.isNullOrBlank() && text != null) {
                bearer.sendTo(to, text)
                android.util.Log.i("HOPLOG", "HOPAUTO sent to=${to.take(8)} text=$text")
            }
        }
    }

    override fun onResume() {
        super.onResume()
        bearer.setForeground(true)
        // android-10: a user who granted permission from App Settings (or elsewhere) recovers without an
        // app relaunch: re-check on resume and start the service the moment the grant appears.
        val nowGranted = requiredGranted()
        if (nowGranted && !bleGranted.value) {
            bleGranted.value = true
            mustUseSettings.value = false
            HopService.start(this)
        } else {
            bleGranted.value = nowGranted
        }
    }
    override fun onPause() { super.onPause(); bearer.setForeground(false) }
}

/** The permission-denied recovery screen (android-10). Explains why Hop needs nearby-device access and
 *  offers either an in-app re-request (system dialog still available) or a deep-link to App Settings
 *  (once the OS will no longer show the dialog). Replaces the old silent, stuck-on-"starting…" dead-end. */
@androidx.compose.runtime.Composable
private fun PermissionGate(
    mustUseSettings: Boolean,
    onGrant: () -> Unit,
    onOpenSettings: () -> Unit,
) {
    Surface(modifier = Modifier.fillMaxSize()) {
        Column(
            modifier = Modifier.fillMaxSize().safeDrawingPadding().padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Text("Nearby-device access needed", style = MaterialTheme.typography.headlineSmall)
            Spacer(Modifier.height(12.dp))
            Text(
                "Hop forms its mesh over Bluetooth LE to nearby phones. Without the nearby-devices " +
                    "(Bluetooth) permission it can't scan, advertise, or relay, so nothing will send " +
                    "or arrive.",
                style = MaterialTheme.typography.bodyMedium,
            )
            Spacer(Modifier.height(24.dp))
            if (mustUseSettings) {
                Text(
                    "You've denied it permanently. Turn it on in App Settings under Permissions → " +
                        "Nearby devices, then return here.",
                    style = MaterialTheme.typography.bodySmall,
                )
                Spacer(Modifier.height(16.dp))
                Button(onClick = onOpenSettings) { Text("Open App Settings") }
            } else {
                Button(onClick = onGrant) { Text("Grant permission") }
            }
        }
    }
}

// cov/android-demo: platformLabel / transportIcon / makeQrBitmap / jpegDownscale / messageMeta /
// normalizeHops / statusText moved to DemoFormat.kt (pure, unit-tested on the JVM). The @Composable
// render bodies below stay here and are excluded from the coverage denominator (UI/device-bound).

/// Render a Font Awesome vector icon, tinted, inside a square `size`×`size` box with ContentScale.Fit
/// so the whole glyph is letterboxed and NEVER clipped (FA paths span the full viewBox — e.g. the lock
/// shackle sits at y=0; constraining a single axis clipped the extremes). For inline status glyphs.
@Composable
private fun FaIcon(res: Int, tint: Color = LocalContentColor.current, size: Dp = 13.dp) {
    Image(
        painter = painterResource(res),
        contentDescription = null,
        colorFilter = ColorFilter.tint(tint),
        contentScale = ContentScale.Fit,
        modifier = Modifier.size(size),
    )
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
                icon = { FaIcon(res = sh.hopme.demo.R.drawable.ic_fa_comments, size = 22.dp) }, label = { Text("Chats") })
            NavigationBarItem(selected = tab == 1, onClick = { tab = 1 },
                icon = { FaIcon(res = sh.hopme.demo.R.drawable.ic_fa_tower_broadcast, size = 22.dp) }, label = { Text("Channels") })
            NavigationBarItem(selected = tab == 2, onClick = { tab = 2 },
                icon = { FaIcon(res = sh.hopme.demo.R.drawable.ic_fa_globe, size = 22.dp) }, label = { Text("Web") })
            NavigationBarItem(selected = tab == 3, onClick = { tab = 3 },
                icon = { FaIcon(res = sh.hopme.demo.R.drawable.ic_fa_gear, size = 22.dp) }, label = { Text("Status") })
        }
    }) { pad ->
        Box(Modifier.padding(pad).imePadding()) {
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
            Row(verticalAlignment = Alignment.CenterVertically) {
                FaIcon(res = if (q.own) sh.hopme.demo.R.drawable.ic_fa_thumbtack else sh.hopme.demo.R.drawable.ic_fa_right_left, size = 12.dp)
                Spacer(Modifier.width(6.dp))
                Text((if (q.own) "yours → " else "relay → ") + "${q.to}  ·  p${q.priority} · ${q.hops}h",
                    style = MaterialTheme.typography.bodySmall)
            }
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
                Button(onClick = { showAdd = true }) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        FaIcon(res = sh.hopme.demo.R.drawable.ic_fa_plus, size = 13.dp)
                        Spacer(Modifier.width(6.dp)); Text("Add")
                    }
                }
            }
            Spacer(Modifier.height(8.dp))
        }
        if (bearer.hpsInvites.isNotEmpty()) {
            item { Text("Invites", style = MaterialTheme.typography.titleMedium) }
            items(bearer.hpsInvites) { inv ->
                ListItem(
                    headlineContent = { Row(verticalAlignment = Alignment.CenterVertically) {
                        FaIcon(res = sh.hopme.demo.R.drawable.ic_fa_envelope, size = 13.dp)
                        Spacer(Modifier.width(6.dp)); Text(inv.path)
                    } },
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
            item { Text("None yet. Tap + Add to host, subscribe, or browse.", style = MaterialTheme.typography.bodySmall) }
        }
        items(bearer.hpsTopics) { t ->
            val unread = bearer.hpsUnread[t.id] ?: 0
            ListItem(
                headlineContent = { Row(verticalAlignment = Alignment.CenterVertically) {
                    FaIcon(res = if (t.channel) sh.hopme.demo.R.drawable.ic_fa_comment else sh.hopme.demo.R.drawable.ic_fa_bullhorn, size = 13.dp)
                    Spacer(Modifier.width(6.dp)); Text(t.path)
                } },
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
            FaIcon(res = if (topic.channel) sh.hopme.demo.R.drawable.ic_fa_comment else sh.hopme.demo.R.drawable.ic_fa_bullhorn, size = 18.dp)
            Spacer(Modifier.width(6.dp))
            Text(topic.path, style = MaterialTheme.typography.titleLarge)
            Spacer(Modifier.weight(1f))
            TextButton(onClick = { showInfo = true }) {
                Icon(painterResource(R.drawable.ic_fa_circle_info), contentDescription = "Info")
            }
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
    var access by remember { mutableStateOf(uniffi.hop.HpsAccess.OPEN) }
    var discoverable by remember { mutableStateOf(false) }
    var subHost by remember { mutableStateOf("") }
    var subPath by remember { mutableStateOf("") }
    var found by remember { mutableStateOf(listOf<uniffi.hop.HpsTopicInfo>()) }

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
                        FilterChip(access == uniffi.hop.HpsAccess.OPEN, { access = uniffi.hop.HpsAccess.OPEN }, label = { Text("Open") })
                        Spacer(Modifier.width(6.dp))
                        FilterChip(access == uniffi.hop.HpsAccess.REQUEST_TO_JOIN, { access = uniffi.hop.HpsAccess.REQUEST_TO_JOIN }, label = { Text("Request") })
                        Spacer(Modifier.width(6.dp))
                        FilterChip(access == uniffi.hop.HpsAccess.INVITE, { access = uniffi.hop.HpsAccess.INVITE }, label = { Text("Invite") })
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
                            supportingContent = { Text((if (t.kind == uniffi.hop.HpsKind.CHANNEL) "channel" else "service") + " · " + HopBearer.shortHex(t.host)) },
                            trailingContent = {
                                TextButton(onClick = { bearer.hpsJoin(t); onDone() }) {
                                    Text(if (t.access == uniffi.hop.HpsAccess.OPEN) "Join" else "Request")
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
            TextButton(onClick = { if (field.isNotBlank()) browseUrl = field }) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    FaIcon(res = sh.hopme.demo.R.drawable.ic_fa_globe, size = 14.dp)
                    Spacer(Modifier.width(6.dp)); Text("Open in browser")
                }
            }
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
    val subline = listOf(HopBearer.shortHex(p.address), platformLabel(p.platform), p.app)
        .filter { it.isNotEmpty() }.joinToString(" · ")
    ListItem(
        leadingContent = {
            Box(Modifier.size(8.dp).clip(CircleShape)
                .background(if (p.active) Color(0xFF34C759) else Color.Gray))
        },
        headlineContent = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(p.name)
                if (locked) {
                    Spacer(Modifier.width(5.dp))
                    FaIcon(sh.hopme.demo.R.drawable.ic_fa_lock, MaterialTheme.colorScheme.primary, 12.dp)
                }
            }
        },
        supportingContent = { Text(subline) },
        trailingContent = {
            val isLive = bearer.peers.any { it.address.contentEquals(p.address) }
            if (!isLive) {
                Text("offline", style = MaterialTheme.typography.bodySmall)
            } else {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    val icon = bearer.linkTransports[p.address.toList()]?.let { transportIcon(it) }
                    if (icon != null) {
                        FaIcon(icon, MaterialTheme.colorScheme.onSurfaceVariant, 12.dp)
                        Spacer(Modifier.width(5.dp))
                    }
                    Text(HopBearer.hopsLabel(p.hops), style = MaterialTheme.typography.bodySmall)
                }
            }
        },
        modifier = Modifier.clickable { onPick(p) },
    )
}

@Composable
fun ChatScreen(bearer: HopBearer, peer: HopBearer.Peer, onBack: () -> Unit) {
    var draft by remember { mutableStateOf("") }
    val attached = remember { mutableStateListOf<ByteArray>() } // staged images for one multipart send
    val thread = bearer.messages.filter { it.peer == bearer.keyFor(peer) }   // key by ADDRESS, not name (two same-named peers must not merge)
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
    Column(Modifier.fillMaxSize().safeDrawingPadding().padding(16.dp)) {
        val locked = bearer.secured.contains(peer.address.toList())
        Row(verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = onBack) { Text("‹ Back") }
            Text(peer.name, style = MaterialTheme.typography.titleLarge)
            if (locked) {
                Spacer(Modifier.width(6.dp))
                FaIcon(sh.hopme.demo.R.drawable.ic_fa_lock, MaterialTheme.colorScheme.primary, 16.dp)
            }
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
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.clickable { bearer.retry(m, peer) },
                        ) {
                            Icon(
                                painterResource(R.drawable.ic_fa_arrows_rotate),
                                contentDescription = "Retry",
                                tint = MaterialTheme.colorScheme.error,
                                modifier = Modifier.size(14.dp),
                            )
                            Spacer(Modifier.width(4.dp))
                            Text("Not sent · tap to retry", color = MaterialTheme.colorScheme.error,
                                style = MaterialTheme.typography.bodySmall)
                        }
                    } else if (!m.incoming && !m.delivered && m.relayed == 0u && !locked) {
                        // Genuinely "Securing": no forward-secret session with THIS recipient yet (no
                        // prekey). Once the session is locked the message HAS been sent — it's awaiting
                        // a delivery ack, NOT securing — so don't keep showing "Securing".
                        SendingIndicator(m.sentAt, peersReachable = bearer.peers.isNotEmpty())
                    } else if (!m.incoming && !m.delivered && m.relayed == 0u) {
                        Text("Sent · awaiting delivery", style = MaterialTheme.typography.bodySmall)
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
                                modifier = Modifier.align(Alignment.TopEnd)) { FaIcon(res = sh.hopme.demo.R.drawable.ic_fa_xmark, size = 12.dp) }
                        }
                    }
                }
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(value = draft, onValueChange = { draft = it },
                modifier = Modifier.weight(1f), placeholder = { Text("Message ${peer.name}") })
            TextButton(onClick = { picker.launch("image/*") }) {
                FaIcon(sh.hopme.demo.R.drawable.ic_fa_camera, MaterialTheme.colorScheme.primary, 20.dp)
            }
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
