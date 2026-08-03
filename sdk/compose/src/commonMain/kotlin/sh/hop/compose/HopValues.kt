// The platform-neutral value types the Compose SDK renders. These live in commonMain so the reactive
// client, the state reducer, and the composables are all fully platform independent: nothing here
// touches JNA, cinterop, or any one native binding. The concrete engine that produces these values is
// supplied through the HopEngine seam (see HopEngine.kt), the same way the core keeps transport behind
// the bearer seam. Kotlin's Double Ratchet, untraceable send path, and durable inbox all live below
// this line, inside the engine; up here we only model what a UI needs to show.

package sh.hop.compose

/** A Hop address: exactly 32 opaque bytes. Value semantics, so it is safe as a map key and a Compose
 *  state field. The raw bytes are copied in and out, so a caller can never scribble on our copy and a
 *  downstream mutation can never corrupt a value we handed around (same ownership rule the JNA
 *  `HopMessage` documents). Base58 rendering is not done here: encoding depends on the native codec, so
 *  the [HopEngine] performs it and the client caches the string alongside the address in [HopPeer]. */
class HopAddress private constructor(private val storage: ByteArray) {
    /** A defensive copy of the 32 raw bytes (mutate freely without affecting this address). */
    fun toBytes(): ByteArray = storage.copyOf()

    override fun equals(other: Any?): Boolean =
        this === other || (other is HopAddress && storage.contentEquals(other.storage))

    override fun hashCode(): Int = storage.contentHashCode()

    /** A short, stable hex tag for logs and fallback labels (never the full address). */
    override fun toString(): String = "HopAddress(" + storage.take(4).joinToString("") {
        val v = it.toInt() and 0xff
        val hi = "0123456789abcdef"[v ushr 4]
        val lo = "0123456789abcdef"[v and 0x0f]
        "$hi$lo"
    } + "..)"

    companion object {
        /** The wire length of every Hop address; the native ABI reads exactly this many bytes. */
        const val LENGTH: Int = 32

        /** Wrap 32 bytes as an address, copying them. Throws if the length is wrong, rather than handing
         *  native code a mis-sized buffer later (the JNA wrapper's `require32` rule, moved up front). */
        fun of(bytes: ByteArray): HopAddress {
            require(bytes.size == LENGTH) { "Hop address must be $LENGTH bytes, got ${bytes.size}" }
            return HopAddress(bytes.copyOf())
        }

        /** Same as [of] but returns null instead of throwing, for parsing untrusted input. */
        fun ofOrNull(bytes: ByteArray?): HopAddress? =
            if (bytes != null && bytes.size == LENGTH) HopAddress(bytes.copyOf()) else null
    }
}

/** How far a message we sent has gotten, folded from the engine's delivery status. Ordered by
 *  progress so a UI can compare states (`state >= HopDelivery.Relayed`). */
enum class HopDelivery {
    /** Queued locally, not yet handed to any peer. */
    Pending,
    /** Handed to at least one relay, no destination confirmation yet. */
    Relayed,
    /** The destination confirmed receipt (an ack came back). */
    Delivered,
    /** The engine reported a permanent send failure. */
    Failed,
}

/** The direction a message travelled relative to this node. */
enum class HopDirection { Inbound, Outbound }

/** One message in a conversation, as the UI sees it. Immutable; the reactive client only ever replaces
 *  a message with a new value (never mutates in place), so it composes cleanly with Compose snapshot
 *  state. [id] is the 32-byte bundle id rendered as lowercase hex, unique enough to be a stable list key
 *  and to correlate an outbound send with its later delivery status. */
data class HopMessage(
    val id: String,
    val peer: HopAddress,
    val direction: HopDirection,
    val contentType: String,
    val body: ByteArray,
    val hops: Int,
    val createdAtMs: Long,
    val delivery: HopDelivery = HopDelivery.Pending,
) {
    /** The body decoded as UTF-8, for the common `text/plain` case. */
    val text: String get() = body.decodeToString()

    /** A defensive copy of the body bytes. */
    fun bodyCopy(): ByteArray = body.copyOf()

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is HopMessage) return false
        return id == other.id && peer == other.peer && direction == other.direction &&
            contentType == other.contentType && body.contentEquals(other.body) && hops == other.hops &&
            createdAtMs == other.createdAtMs && delivery == other.delivery
    }

    override fun hashCode(): Int {
        var r = id.hashCode()
        r = 31 * r + peer.hashCode()
        r = 31 * r + direction.hashCode()
        r = 31 * r + contentType.hashCode()
        r = 31 * r + body.contentHashCode()
        r = 31 * r + hops
        r = 31 * r + createdAtMs.hashCode()
        r = 31 * r + delivery.hashCode()
        return r
    }
}

/** A peer we have exchanged messages with, plus what we know about it: its base58 rendering (computed
 *  once by the engine, cached here), an optional display name from presence, and whether we currently
 *  hold a forward-secret session with it. A UI shows [name] when present and falls back to [base58]. */
data class HopPeer(
    val address: HopAddress,
    val base58: String,
    val name: String? = null,
    val secured: Boolean = false,
) {
    /** The label a UI should show: the presence name if we have one, else the short base58 head. */
    val displayName: String get() = name ?: (base58.take(8) + if (base58.length > 8) "..." else "")
}

/** The outcome of a [HopClient.send]. Carries the bundle id so a caller can await delivery, or the
 *  reason a send never left the node. */
sealed interface HopSendResult {
    /** The send was accepted by the engine; [id] is the hex bundle id, correlating to later status. */
    data class Accepted(val id: String) : HopSendResult
    /** The engine rejected the send (bad address, closed node, native error). */
    data class Rejected(val reason: String) : HopSendResult
}
