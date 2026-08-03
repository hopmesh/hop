// The engine seam. A HopEngine is whatever actually runs a Hop node: on JVM (Android + Desktop) it is
// the JNA `sh.hop.HopNode` behind JnaHopEngine; on iOS it is an adapter over the Apple xcframework that
// the app supplies. The Compose SDK depends ONLY on this interface, never on a concrete binding, for the
// same reason the core keeps transport behind the bearer seam: the UI layer must not hard-wire itself to
// one platform's FFI. Everything above this seam (HopClient, the reducer, the composables) is pure
// commonMain and is tested against a fake engine, so the reactive behaviour is verified with no native
// library present.
//
// Threading contract: an engine is NOT assumed thread-safe. HopClient confines every call to a single
// coroutine (its own dispatcher), never touching the engine from two coroutines at once. An engine
// implementation therefore does not need its own lock beyond what its native handle already provides.

package sh.hop.compose

/** The minimal node surface the Compose SDK drives. Deliberately small: it is the projection of
 *  `libhop` that a messaging UI needs, not the whole ABI. A backend service SDK would bind more; a UI
 *  binds this. All methods run inside the client's single confinement coroutine (see the file header). */
interface HopEngine {
    /** This node's own 32-byte address. */
    fun address(): HopAddress

    /** Render an address as base58 using the native codec (the one encoding the UI must not reinvent). */
    fun base58(address: HopAddress): String

    /** Parse a base58 string to an address, or null if it is not exactly a 32-byte address. */
    fun addressFromBase58(text: String): HopAddress?

    /** Advance the node's clock to [nowMs]. The client calls this on every loop tick so held messages,
     *  ratchet timers, and retransmissions make progress. */
    fun tick(nowMs: Long)

    /** Publish a prekey so peers can open a forward-secret session with us. Returns false if nothing was
     *  published (for example no bearer is up yet); the client simply retries on the next tick. */
    fun publishPrekey(): Boolean

    /** Set the display name reported through presence / hop.identify. */
    fun setName(name: String)

    /** Whether we hold a live forward-secret (Double Ratchet) session with [peer]. */
    fun isSecured(peer: HopAddress): Boolean

    /** Send an untraceable (address-sealed) message. Returns the 32-byte bundle id, or null on error.
     *  This is the default path: no address goes on the wire. */
    fun send(to: HopAddress, contentType: String, body: ByteArray, requestAck: Boolean): ByteArray?

    /** Drain newly-arrived durable messages. The engine hands each item to [onMessage]; returning true
     *  durably accepts it (so it is not redelivered), false leaves it queued for a later poll. The client
     *  accepts only after it has folded the message into state, so a crash mid-drain never loses a
     *  message: it is simply re-polled next tick. */
    fun pollInbox(onMessage: (EngineMessage) -> Boolean)

    /** The current delivery status of a message we sent, keyed by its 32-byte bundle id. */
    fun statusOf(id: ByteArray): EngineStatus

    /** Release the native node. Idempotent. After this, no other method is called. */
    fun close()
}

/** The raw shape the engine reports for an inbound message, before the client turns it into a UI
 *  [HopMessage]. Kept separate so the engine surface stays in ABI-adjacent terms (raw 32-byte ids and
 *  addresses) while the UI type carries hex ids and [HopAddress] value objects. */
data class EngineMessage(
    val id: ByteArray,
    val from: ByteArray,
    val contentType: String,
    val body: ByteArray,
    val hops: Int,
    val createdAtMs: Long,
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is EngineMessage) return false
        return id.contentEquals(other.id) && from.contentEquals(other.from) &&
            contentType == other.contentType && body.contentEquals(other.body) &&
            hops == other.hops && createdAtMs == other.createdAtMs
    }

    override fun hashCode(): Int {
        var r = id.contentHashCode()
        r = 31 * r + from.contentHashCode()
        r = 31 * r + contentType.hashCode()
        r = 31 * r + body.contentHashCode()
        r = 31 * r + hops
        r = 31 * r + createdAtMs.hashCode()
        return r
    }
}

/** The delivery status the engine reports for a sent message. */
data class EngineStatus(
    val relayed: Int,
    val delivered: Boolean,
    val forwardHops: Int,
    val forwardMs: Int,
) {
    /** Fold the raw counters into the UI-facing [HopDelivery] ladder. */
    fun toDelivery(): HopDelivery = when {
        delivered -> HopDelivery.Delivered
        relayed > 0 -> HopDelivery.Relayed
        else -> HopDelivery.Pending
    }
}
