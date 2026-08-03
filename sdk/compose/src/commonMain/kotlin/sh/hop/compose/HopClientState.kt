// The immutable UI state the reactive client publishes, and the pure reducer that folds engine events
// into it. Kept free of coroutines and native code on purpose: the reducer is a plain function of
// (state, event) -> state, so the whole grouping-and-ordering behaviour is unit tested with no engine,
// no dispatcher, and no Compose runtime. HopClient (HopClient.kt) is the only thing that runs it.

package sh.hop.compose

/** A conversation with one peer: the peer we know, and its messages oldest-first. Derived entirely from
 *  the message log by the reducer, so it never drifts from the source of truth. */
data class HopConversation(
    val peer: HopPeer,
    val messages: List<HopMessage>,
) {
    /** The most recent message, or null for an empty conversation (which the reducer never emits). */
    val lastMessage: HopMessage? get() = messages.lastOrNull()

    /** How many inbound messages arrived at or after [sinceMs] (a simple unread proxy for a UI badge). */
    fun inboundSince(sinceMs: Long): Int =
        messages.count { it.direction == HopDirection.Inbound && it.createdAtMs >= sinceMs }
}

/** Everything a Hop messaging UI renders, in one immutable snapshot. The client exposes this as a
 *  StateFlow; every change replaces the whole value, so Compose recomposes from a single source. */
data class HopClientState(
    /** This node's own address, once the engine has started. Null before the first tick. */
    val self: HopPeer? = null,
    /** Whether the client's tick loop is running. */
    val running: Boolean = false,
    /** Conversations, most-recently-active first. */
    val conversations: List<HopConversation> = emptyList(),
    /** The last error the loop surfaced, if any (cleared when the next tick succeeds). */
    val lastError: String? = null,
) {
    /** Find the conversation with [peer], or null if none has started. */
    fun conversation(peer: HopAddress): HopConversation? =
        conversations.firstOrNull { it.peer.address == peer }

    /** Every message across every conversation, newest-first, for a unified timeline view. */
    fun allMessages(): List<HopMessage> =
        conversations.flatMap { it.messages }.sortedByDescending { it.createdAtMs }
}

/** The events the reducer folds. These are produced by [HopClient] from engine polls and local sends;
 *  the reducer itself is what keeps state consistent, so both real and test paths share one code path. */
sealed interface HopEvent {
    /** The engine started; we learned our own identity. */
    data class Started(val self: HopPeer) : HopEvent

    /** The loop stopped (close, or a fatal engine error carried in [error]). */
    data class Stopped(val error: String?) : HopEvent

    /** A message arrived or was sent. For outbound sends the client emits this immediately with
     *  [HopDelivery.Pending] so the UI shows the message before any ack. */
    data class MessageObserved(val message: HopMessage, val peer: HopPeer) : HopEvent

    /** A sent message's delivery advanced. Matched to an existing message by [id]. */
    data class DeliveryChanged(val id: String, val delivery: HopDelivery) : HopEvent

    /** Fresh presence/security facts about a peer (name, secured session), merged onto its record. */
    data class PeerUpdated(val peer: HopPeer) : HopEvent
}

/** The pure state transition. Total (never throws) and deterministic: the same (state, event) always
 *  yields the same next state, which is what makes the client's behaviour testable without an engine.
 *
 *  Ordering rules, all enforced here so the UI never has to sort:
 *   - messages within a conversation are oldest-first, keyed by [HopMessage.id] (a repeat id updates in
 *     place rather than duplicating, so a re-polled-but-not-yet-accepted inbox item is idempotent);
 *   - conversations are most-recently-active first (by their newest message's timestamp);
 *   - a [DeliveryChanged] for an unknown id is ignored rather than inventing an empty conversation. */
fun reduceHopState(state: HopClientState, event: HopEvent): HopClientState = when (event) {
    is HopEvent.Started -> state.copy(self = event.self, running = true, lastError = null)

    is HopEvent.Stopped -> state.copy(running = false, lastError = event.error)

    is HopEvent.MessageObserved -> {
        val convos = upsertMessage(state.conversations, event.peer, event.message)
        state.copy(conversations = sortConversations(convos), lastError = null)
    }

    is HopEvent.DeliveryChanged -> {
        var touched = false
        val convos = state.conversations.map { convo ->
            val idx = convo.messages.indexOfFirst { it.id == event.id }
            if (idx < 0) convo else {
                touched = true
                val updated = convo.messages.toMutableList()
                updated[idx] = updated[idx].copy(delivery = event.delivery)
                convo.copy(messages = updated)
            }
        }
        if (touched) state.copy(conversations = convos) else state
    }

    is HopEvent.PeerUpdated -> {
        val convos = state.conversations.map { convo ->
            if (convo.peer.address == event.peer.address) convo.copy(peer = event.peer) else convo
        }
        val self = if (state.self?.address == event.peer.address) event.peer else state.self
        state.copy(conversations = convos, self = self)
    }
}

/** Insert-or-update a message into the right conversation, creating the conversation if new. */
private fun upsertMessage(
    conversations: List<HopConversation>,
    peer: HopPeer,
    message: HopMessage,
): List<HopConversation> {
    val existingIdx = conversations.indexOfFirst { it.peer.address == peer.address }
    if (existingIdx < 0) {
        return conversations + HopConversation(peer = peer, messages = listOf(message))
    }
    val convo = conversations[existingIdx]
    val msgs = convo.messages.toMutableList()
    val msgIdx = msgs.indexOfFirst { it.id == message.id }
    if (msgIdx >= 0) msgs[msgIdx] = message else insertByTime(msgs, message)
    val result = conversations.toMutableList()
    // Keep the richer peer record: presence facts (name/secured) survive a bare message-only update.
    result[existingIdx] = convo.copy(peer = mergePeer(convo.peer, peer), messages = msgs)
    return result
}

/** Insert [message] into an oldest-first list at the position its timestamp implies (stable for ties). */
private fun insertByTime(msgs: MutableList<HopMessage>, message: HopMessage) {
    var i = msgs.size
    while (i > 0 && msgs[i - 1].createdAtMs > message.createdAtMs) i--
    msgs.add(i, message)
}

/** Prefer the incoming peer's presence facts when it carries them, else keep what we already knew. */
private fun mergePeer(current: HopPeer, incoming: HopPeer): HopPeer = current.copy(
    base58 = incoming.base58.ifEmpty { current.base58 },
    name = incoming.name ?: current.name,
    secured = incoming.secured || current.secured,
)

/** Most-recently-active conversation first; empties (which never occur) sort last defensively. */
private fun sortConversations(conversations: List<HopConversation>): List<HopConversation> =
    conversations.sortedByDescending { it.lastMessage?.createdAtMs ?: Long.MIN_VALUE }
