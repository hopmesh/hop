// The Compose Multiplatform UI. These composables render a HopClient's reactive state and route user
// actions back through it. They are commonMain, so the SAME conversation list, message bubbles, and
// composer render on Android, Desktop, and iOS from one source. They are intentionally unopinionated
// Material 3 building blocks: an app themes them with its own MaterialTheme and can drop any one of them
// into an existing screen, or use HopConversationScreen for a batteries-included chat view.
//
// The seam holds here too: a composable only ever reads HopClient.state and calls HopClient methods. It
// never sees an engine, a coroutine dispatcher, or a native handle.

package sh.hop.compose

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch

/** Build a [HopClient] bound to this composition, start it, and stop it when the composable leaves.
 *
 *  The client's scope is the composition's coroutine scope, so its loop lives exactly as long as the UI
 *  that uses it. Pass the [engine] your platform provides (JnaHopEngine on JVM, an Apple-SDK adapter on
 *  iOS). The returned client is stable across recompositions (keyed on the engine identity). */
@Composable
fun rememberHopClient(
    engine: HopEngine,
    config: HopClientConfig = HopClientConfig(),
): HopClient {
    val scope = rememberCoroutineScope()
    val client = remember(engine) { HopClient(engine, scope, config) }
    DisposableEffect(client) {
        client.start()
        onDispose { client.stop() }
    }
    return client
}

/** A batteries-included one-peer chat screen: the message history plus a composer wired to send. Drop
 *  it into a route with a [client] and the [peer] you are chatting with. */
@Composable
fun HopConversationScreen(
    client: HopClient,
    peer: HopAddress,
    modifier: Modifier = Modifier,
) {
    val state by client.state.collectAsState()
    val convo = state.conversation(peer)
    val scope = rememberCoroutineScope()
    Column(modifier = modifier.fillMaxSize()) {
        HopMessageList(
            messages = convo?.messages.orEmpty(),
            modifier = Modifier.fillMaxWidth().weight(1f),
        )
        HopMessageComposer(
            onSend = { text -> scope.launch { client.sendText(peer, text) } },
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

/** The scrolling message history for one conversation, newest at the bottom, auto-scrolling on arrival. */
@Composable
fun HopMessageList(
    messages: List<HopMessage>,
    modifier: Modifier = Modifier,
) {
    val listState = rememberLazyListState()
    LaunchedEffect(messages.size) {
        if (messages.isNotEmpty()) listState.animateScrollToItem(messages.lastIndex)
    }
    LazyColumn(
        state = listState,
        modifier = modifier.padding(horizontal = 12.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        items(messages, key = { it.id }) { msg -> HopMessageBubble(msg) }
    }
}

/** One message, aligned right (outbound) or left (inbound), with a delivery hint for our own sends. */
@Composable
fun HopMessageBubble(message: HopMessage, modifier: Modifier = Modifier) {
    val outbound = message.direction == HopDirection.Outbound
    val bubbleColor = if (outbound) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.surfaceVariant
    val textColor = if (outbound) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurfaceVariant
    Row(
        modifier = modifier.fillMaxWidth(),
        horizontalArrangement = if (outbound) Arrangement.End else Arrangement.Start,
    ) {
        Column(horizontalAlignment = if (outbound) Alignment.End else Alignment.Start) {
            Surface(
                color = bubbleColor,
                shape = RoundedCornerShape(14.dp),
                modifier = Modifier.widthIn(max = 280.dp),
            ) {
                Text(
                    text = if (message.contentType.startsWith("text/")) message.text else "[${message.contentType}]",
                    color = textColor,
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                )
            }
            if (outbound) {
                Text(
                    text = message.delivery.label(),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.outline,
                    modifier = Modifier.padding(top = 2.dp, end = 4.dp),
                )
            }
        }
    }
}

/** A list of conversations for a home screen: each peer, its last message, and a delivery/security hint.
 *  [onOpen] fires with the peer address when a row is tapped. */
@Composable
fun HopConversationList(
    client: HopClient,
    onOpen: (HopAddress) -> Unit,
    modifier: Modifier = Modifier,
) {
    val state by client.state.collectAsState()
    LazyColumn(modifier = modifier.fillMaxSize()) {
        items(state.conversations, key = { it.peer.base58 }) { convo ->
            HopConversationRow(convo, onClick = { onOpen(convo.peer.address) })
        }
    }
}

@Composable
private fun HopConversationRow(convo: HopConversation, onClick: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick).padding(16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(convo.peer.displayName, style = MaterialTheme.typography.titleSmall)
                if (convo.peer.secured) {
                    Spacer(Modifier.padding(horizontal = 3.dp))
                    HopSecuredDot()
                }
            }
            val last = convo.lastMessage
            if (last != null) {
                Text(
                    text = if (last.contentType.startsWith("text/")) last.text else "[${last.contentType}]",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

/** A one-line composer: a text field and a send button. Clears on send; ignores blank input. */
@Composable
fun HopMessageComposer(
    onSend: (String) -> Unit,
    modifier: Modifier = Modifier,
    placeholder: String = "Message",
) {
    var draft by remember { mutableStateOf("") }
    fun fire() {
        val text = draft.trim()
        if (text.isNotEmpty()) {
            onSend(text)
            draft = ""
        }
    }
    Row(
        modifier = modifier.padding(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        OutlinedTextField(
            value = draft,
            onValueChange = { draft = it },
            modifier = Modifier.weight(1f),
            placeholder = { Text(placeholder) },
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
            keyboardActions = KeyboardActions(onSend = { fire() }),
            maxLines = 4,
        )
        IconButton(onClick = { fire() }) {
            // A simple send glyph without pulling in the material-icons-extended artifact.
            Text("↑", style = MaterialTheme.typography.titleLarge)
        }
    }
}

/** A compact chip showing an address as base58, tappable to copy or open. Falls back to a short head so
 *  it never overflows a row. */
@Composable
fun HopAddressChip(
    base58: String,
    modifier: Modifier = Modifier,
    onClick: (() -> Unit)? = null,
) {
    val head = if (base58.length > 12) base58.take(6) + "..." + base58.takeLast(4) else base58
    Surface(
        shape = RoundedCornerShape(8.dp),
        color = MaterialTheme.colorScheme.secondaryContainer,
        modifier = modifier.then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier),
    ) {
        Text(
            text = head,
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSecondaryContainer,
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp),
        )
    }
}

/** A small green dot indicating a live forward-secret session with a peer. */
@Composable
private fun HopSecuredDot() {
    Box(
        modifier = Modifier
            .padding(1.dp)
            .background(Color(0xFF3DDC84), shape = RoundedCornerShape(50))
            .padding(4.dp),
    )
}

private fun HopDelivery.label(): String = when (this) {
    HopDelivery.Pending -> "sending"
    HopDelivery.Relayed -> "relayed"
    HopDelivery.Delivered -> "delivered"
    HopDelivery.Failed -> "failed"
}
