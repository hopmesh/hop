package net.waldrip.hop.demo

import android.Manifest
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
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
import androidx.compose.ui.unit.dp

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
    if (peer == null) {
        PeopleScreen(bearer) { selected = it }
    } else {
        ChatScreen(bearer, peer) { selected = null }
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
    Column(Modifier.fillMaxSize().padding(16.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = onBack) { Text("‹ Back") }
            val locked = bearer.secured.contains(peer.address.toList())
            Text(peer.name + if (locked) "  🔒" else "", style = MaterialTheme.typography.titleLarge)
        }
        LazyColumn(Modifier.weight(1f)) {
            items(thread) { m ->
                Column(Modifier.padding(vertical = 4.dp)) {
                    Text((if (m.incoming) "‹ " else "› ") + m.text)
                    Text(messageMeta(m), style = MaterialTheme.typography.bodySmall)
                }
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(value = draft, onValueChange = { draft = it },
                modifier = Modifier.weight(1f), placeholder = { Text("Message ${peer.name}") })
            Button(onClick = {
                val t = draft.trim()
                if (t.isNotEmpty()) { bearer.send(t, peer); draft = "" }
            }) { Text("Send") }
        }
    }
}
