// HopClient: the reactive brain. It owns a HopEngine, runs the node's tick loop on a coroutine, and
// publishes an immutable HopClientState as a StateFlow plus a hot inbox Flow of new inbound messages.
// The UI observes; it never touches the engine. All engine access is serialized through one Mutex, so
// the engine (which is not assumed thread-safe) is only ever entered by one coroutine at a time, exactly
// as HopEngine's contract requires.
//
// Everything here is commonMain. It is exercised in commonTest against FakeHopEngine with an injected
// clock and a test dispatcher, so the loop, the send path, the delivery-status tracking, and the state
// wiring are all verified with no native library present.

package sh.hop.compose

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Tuning for the client's loop. Defaults are sensible for an interactive UI: a five-per-second tick is
 *  responsive without spinning, and a prekey republish every few seconds keeps sessions openable. */
data class HopClientConfig(
    /** Milliseconds between loop ticks. Each tick advances the clock, polls the inbox, and refreshes
     *  the delivery status of outstanding sends. */
    val tickIntervalMs: Long = 200,
    /** Republish a prekey every this many ticks (so peers can open a forward-secret session). */
    val prekeyEveryTicks: Int = 25,
    /** Stop refreshing a sent message's status once it is Delivered or Failed, or after this many ticks
     *  without progress, so the status map does not grow without bound in a long session. */
    val statusPollTicks: Int = 300,
    /** Optional durable persistence hook. Return true only after the message is committed;
     *  false defers acceptance in libhop so it is redelivered across restarts. */
    val onPersistInbox: ((HopMessage) -> Boolean)? = null,
)

/** A running Hop node, projected as reactive state for a Compose UI.
 *
 *  Lifecycle: construct with an [engine] and a [scope] (on Android, a viewmodel or composition scope;
 *  on Desktop, an application scope). Call [start] to launch the loop, [stop] to end it and close the
 *  engine. The client is single-use: once stopped it does not restart.
 */
class HopClient(
    private val engine: HopEngine,
    private val scope: CoroutineScope,
    private val config: HopClientConfig = HopClientConfig(),
    private val clock: () -> Long = ::hopNowMillis,
) {
    private val engineLock = Mutex()

    private val _state = MutableStateFlow(HopClientState())
    /** The whole UI state, as one immutable snapshot that changes on every relevant event. */
    val state: StateFlow<HopClientState> = _state.asStateFlow()

    // Replay 0: the inbox is for reacting to NEW arrivals (notifications, sounds); the durable log lives
    // in [state]. extraBufferCapacity keeps a burst of arrivals from suspending the loop.
    private val _inbox = MutableSharedFlow<HopMessage>(replay = 0, extraBufferCapacity = 64)
    /** A hot stream of freshly-arrived inbound messages, for side effects a UI wants exactly once. */
    val inbox: SharedFlow<HopMessage> = _inbox.asSharedFlow()

    // Outbound sends we are still tracking for delivery status: hex id -> tracking record.
    private val tracked = mutableMapOf<String, Tracked>()
    private var loop: Job? = null
    private var engineClosed = false

    private class Tracked(val rawId: ByteArray, var delivery: HopDelivery, var ticksLeft: Int)

    /** Start the tick loop. Idempotent: a second call while running is a no-op. */
    fun start() {
        if (loop?.isActive == true) return
        loop = scope.launch {
            val self = withEngine {
                val addr = it.address()
                HopPeer(address = addr, base58 = it.base58(addr), secured = false)
            }
            emit(HopEvent.Started(self))
            var tick = 0
            try {
                while (isActive) {
                    runTick(tick)
                    tick++
                    delay(config.tickIntervalMs)
                }
            } finally {
                // Covers the scope-cancelled path (a composition leaving the screen): the loop's own
                // coroutine runs this finally even when its scope cancels it, and NonCancellable lets the
                // suspending teardown complete rather than being cut short. The explicit stop() path tears
                // down via its own scope task; teardown() is idempotent, so a race between the two is safe.
                withContext(NonCancellable) { teardown() }
            }
        }
    }

    /** One iteration of the loop, factored out so a test can drive ticks deterministically. */
    internal suspend fun runTick(tick: Int) {
        val now = clock()
        withEngine { it.tick(now) }
        if (config.prekeyEveryTicks > 0 && tick % config.prekeyEveryTicks == 0) {
            withEngine { it.publishPrekey() }
        }
        drainInbox(now)
        refreshDeliveries()
    }

    private suspend fun drainInbox(now: Long) {
        val arrived = mutableListOf<HopMessage>()
        withEngine { e ->
            e.pollInbox { raw ->
                val peerAddr = HopAddress.of(raw.from)
                val peer = HopPeer(
                    address = peerAddr,
                    base58 = e.base58(peerAddr),
                    secured = e.isSecured(peerAddr),
                )
                val msg = HopMessage(
                    id = raw.id.toHex(),
                    peer = peerAddr,
                    direction = HopDirection.Inbound,
                    contentType = raw.contentType,
                    body = raw.body,
                    hops = raw.hops,
                    createdAtMs = raw.createdAtMs,
                    delivery = HopDelivery.Delivered, // an inbound message, from our side, is simply here.
                )
                val accepted = config.onPersistInbox?.invoke(msg) ?: true
                if (accepted) {
                    emitObserved(msg, peer)
                    arrived += msg
                }
                accepted
            }
        }
        for (m in arrived) _inbox.emit(m)
    }

    private suspend fun refreshDeliveries() {
        if (tracked.isEmpty()) return
        val done = mutableListOf<String>()
        // Snapshot the entries so the engine calls do not iterate a map we mutate.
        for ((hexId, rec) in tracked.entries.map { it.key to it.value }) {
            val status = withEngine { it.statusOf(rec.rawId) }
            val next = status.toDelivery()
            if (next != rec.delivery) {
                rec.delivery = next
                emit(HopEvent.DeliveryChanged(hexId, next))
            }
            rec.ticksLeft -= 1
            if (next == HopDelivery.Delivered || next == HopDelivery.Failed || rec.ticksLeft <= 0) {
                done += hexId
            }
        }
        done.forEach { tracked.remove(it) }
    }

    /** Send a message. Optimistically shows it in state (Pending) before any ack, then tracks its
     *  delivery so the UI badge advances to Relayed / Delivered on its own. */
    suspend fun send(
        to: HopAddress,
        body: ByteArray,
        contentType: String = "text/plain",
        requestAck: Boolean = true,
    ): HopSendResult {
        val now = clock()
        val rawId = withEngine { it.send(to, contentType, body, requestAck) }
            ?: return HopSendResult.Rejected("engine rejected the send")
        val hexId = rawId.toHex()
        val peer = withEngine { e ->
            HopPeer(address = to, base58 = e.base58(to), secured = e.isSecured(to))
        }
        val msg = HopMessage(
            id = hexId,
            peer = to,
            direction = HopDirection.Outbound,
            contentType = contentType,
            body = body,
            hops = 0,
            createdAtMs = now,
            delivery = HopDelivery.Pending,
        )
        emitObserved(msg, peer)
        if (requestAck) tracked[hexId] = Tracked(rawId, HopDelivery.Pending, config.statusPollTicks)
        return HopSendResult.Accepted(hexId)
    }

    /** Convenience for the common UTF-8 text send. */
    suspend fun sendText(to: HopAddress, text: String, requestAck: Boolean = true): HopSendResult =
        send(to, text.encodeToByteArray(), "text/plain", requestAck)

    /** Set this node's display name (reported through presence). Reflected into [state] immediately. */
    suspend fun setName(name: String) {
        withEngine { it.setName(name) }
        val self = _state.value.self ?: return
        emit(HopEvent.PeerUpdated(self.copy(name = name)))
    }

    /** Parse a base58 address using the engine's native codec. Null if not a valid 32-byte address. */
    suspend fun parseAddress(text: String): HopAddress? = withEngine { it.addressFromBase58(text) }

    /** Base58 of an address using the engine's native codec. */
    suspend fun formatAddress(address: HopAddress): String = withEngine { it.base58(address) }

    /** Stop the loop and close the engine. Idempotent. Teardown runs as its own task on [scope] so it
     *  completes deterministically whether or not the loop had started its run; the loop's cancellation
     *  finally is the backstop for the scope-cancelled path. */
    fun stop() {
        loop?.cancel()
        loop = null
        scope.launch { teardown() }
    }

    // Mark stopped and free the engine, exactly once. Both stop() and the loop finally call this; the
    // engineClosed flag plus the lock make concurrent or repeated calls safe.
    private suspend fun teardown() {
        emit(HopEvent.Stopped(error = null))
        closeEngineOnce()
    }

    // Close the engine exactly once, under the lock so we never free the native handle out from under an
    // in-flight call. Idempotent regardless of how many stop paths race.
    private suspend fun closeEngineOnce() = engineLock.withLock {
        if (!engineClosed) {
            engineClosed = true
            engine.close()
        }
    }

    // Non-suspend on purpose: it is called from inside the (non-suspend) pollInbox callback, and it only
    // wraps the synchronous state reduction. The hot-inbox emit, which IS suspend, stays outside that
    // callback (see drainInbox), so nothing suspends while we hold the engine lock across a native poll.
    private fun emitObserved(message: HopMessage, peer: HopPeer) =
        emit(HopEvent.MessageObserved(message, peer))

    private fun emit(event: HopEvent) {
        _state.value = reduceHopState(_state.value, event)
    }

    private suspend fun <T> withEngine(block: (HopEngine) -> T): T = engineLock.withLock { block(engine) }
}

/** Lowercase hex, the stable string form of a 32-byte id used as a Compose list key. */
internal fun ByteArray.toHex(): String {
    val sb = StringBuilder(size * 2)
    for (b in this) {
        val v = b.toInt() and 0xff
        sb.append("0123456789abcdef"[v ushr 4])
        sb.append("0123456789abcdef"[v and 0x0f])
    }
    return sb.toString()
}
