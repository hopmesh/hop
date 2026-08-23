// Hop - the idiomatic Kotlin face of libhop's C ABI (hop.h), via JNA. Same role as the Swift `Hop`
// wrapper: a thin, type-safe shim over the generated C contract (so it can't drift). Android bearers
// and the app use this; on Android the same .so is loaded, here (host JVM) it is libhop.dylib.

package sh.hop

import com.sun.jna.Callback
import com.sun.jna.Library
import com.sun.jna.Native
import com.sun.jna.NativeLong
import com.sun.jna.Pointer
import com.sun.jna.ptr.ByteByReference
import com.sun.jna.ptr.IntByReference
import com.sun.jna.ptr.NativeLongByReference
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/** Which side opened a bearer link (the Noise role). */
enum class HopRole(val c: Int) { DIALER(0), ACCEPTOR(1) }

// ---- §32 hps:// pub/sub enums (HopHpsKind / HopHpsAccess / HopHpsVisibility in hop.h) ----------
//
// All three cross the C ABI as a plain uint32_t discriminant, so `c` is the exact int the native
// call expects. An OUT-OF-RANGE value FAILS the native call rather than being defaulted, and this
// wrapper must never paper over that: reading a garbage int as `OPEN` would hand a topic's content
// key to anyone who asks. An exhaustive Kotlin enum is what keeps a bad discriminant unreachable
// from this side in the first place.

/** What a topic at a path IS: a channel every member writes to, or a service only its owner broadcasts. */
enum class HpsKind(val c: Int) { CHANNEL(0), SERVICE(1) }

/** Who may obtain a topic's keys. This is the whole membership boundary: a Hop group message is ONE
 *  content-key-encrypted, per-writer-signed publication flooded once, not one-to-one fan-out and not
 *  a multicast bundle, so membership, invites and revocation are properties of the key handoff and of
 *  nothing else. */
enum class HpsAccess(val c: Int) { OPEN(0), REQUEST_TO_JOIN(1), INVITE(2) }

/** Whether the host broadcasts an (app-encrypted) discovery advert so same-app peers can browse it. */
enum class HpsVisibility(val c: Int) { PRIVATE(0), DISCOVERABLE(1) }

/** Decode a `kind` discriminant the LIBRARY produced (a poll or list callback), defaulting an unknown
 *  one to [HpsKind.CHANNEL] for display.
 *
 *  Safe on the way OUT, and only there: these ints come from libhop's own enum, so an unknown value
 *  means the library is newer than this wrapper and the honest fallback is to render the topic as an
 *  ordinary channel rather than drop it off the list. The same defaulting on the way IN would be a
 *  security bug, which is why [HpsKind.c] is the only thing ever handed to a native call. */
private fun hpsKindOf(c: Int): HpsKind = HpsKind.entries.firstOrNull { it.c == c } ?: HpsKind.CHANNEL

/** Decode an `access` discriminant the LIBRARY produced, defaulting an unknown one to
 *  [HpsAccess.OPEN] for display only. See [hpsKindOf]: this direction only ever describes a topic the
 *  node already holds, so the fallback grants nothing. Never do this to a value on its way IN. */
private fun hpsAccessOf(c: Int): HpsAccess = HpsAccess.entries.firstOrNull { it.c == c } ?: HpsAccess.OPEN

/** §19 relay-pool counts: [total] endpoints known, [available] dialable right now.
 *
 *  `total > 0` with `available == 0` is the degraded "everything backed off" state a UI should show
 *  as such rather than as offline; the pool still knows where to retry. */
data class HopRelayPool(val total: Int, val available: Int)

/** A decrypted message delivered to this node.
 *
 *  Ownership: [from] and [body] are freshly-allocated snapshots owned by this value (never aliased to
 *  any libhop-internal buffer), so the wrapper's own state can't be corrupted through them. They are,
 *  however, still mutable arrays a downstream caller could scribble on and thereby corrupt a value it
 *  passed around. Treat them as read-only; use [fromCopy] / [bodyCopy] when handing the bytes to code
 *  that might mutate them (a `data class` can't return defensive copies from its generated accessors).
 *  equals/hashCode are content-based (value semantics); as with any value carrying a mutable array, do
 *  not mutate a field and then rely on it as a HashMap/HashSet key. */
// F-9: `hops` is `UByte`, not `Byte`. The C ABI field is uint8_t (0..255) and the UniFFI-generated
// driver bindings expose the equivalent field as UByte; a signed Byte would render a hop count >= 128
// as a negative number. The FFI boundary itself (InboxSink.invoke, hop_message_status) keeps Byte for
// correct JNA marshalling of a native uint8_t; we reinterpret to UByte at this public surface.
data class HopMessage(val from: ByteArray, val contentType: String, val body: ByteArray, val hops: UByte, val createdAt: Long,
                      val id: ByteArray = ByteArray(32)) {
    /** A defensive copy of the sender address (mutate this freely without affecting the message). */
    fun fromCopy(): ByteArray = from.copyOf()
    /** A defensive copy of the body bytes (mutate this freely without affecting the message). */
    fun bodyCopy(): ByteArray = body.copyOf()

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is HopMessage) return false
        return from.contentEquals(other.from) && contentType == other.contentType &&
            body.contentEquals(other.body) && hops == other.hops && createdAt == other.createdAt &&
            id.contentEquals(other.id)
    }
    override fun hashCode(): Int {
        var r = from.contentHashCode()
        r = 31 * r + contentType.hashCode()
        r = 31 * r + body.contentHashCode()
        r = 31 * r + hops.toInt()
        r = 31 * r + createdAt.hashCode()
        r = 31 * r + id.contentHashCode()
        return r
    }
}

/** Delivery status of a message we sent. Mirrors Swift `HopStatus` (hop_message_status out-params).
 *  All fields are immutable primitives (no mutable ByteArray), so there is no shared-state hazard here. */
data class HopStatus(
    /** Distinct peers handed a copy. */
    val relayed: Int,
    /** Destination confirmed. */
    val delivered: Boolean,
    /** Forward-path length the destination reported. `UByte`, not `Byte`: the C ABI field is uint8_t
     *  (0..255), so a signed Byte would render a forward-hop count >= 128 as negative (pass-18 F-1, the
     *  sibling of the HopMessage.hops F-9 fix). The FFI boundary keeps Byte for correct JNA marshalling;
     *  we reinterpret to UByte at this public surface. */
    val forwardHops: UByte,
    /** Forward-path latency (ms) the destination reported. */
    val forwardMs: Int,
)

/** The raw JNA binding - one function per `hop_*` symbol. Internal; callers use [HopNode].
 *
 *  bool-return marshalling: libhop's C ABI returns a 1-byte C `_Bool` (0 or 1) in the low byte of the
 *  return register. The x86-64 SysV ABI does NOT require the upper bits to be zeroed on a `false`
 *  return, and JNA's `boolean` return mapping reads a full-width int, so a `false` left with dirty
 *  upper bits misreads as `true` (seen only on x86-64 Linux; arm64 happens to zero-extend). Every
 *  bool-returning native is declared to return [Byte] here so libffi reads exactly the low byte; the
 *  Kotlin wrappers convert with [toBool]. Do NOT change these back to Boolean. */
internal interface CHop : Library {
    fun hop_node_new(): Pointer?
    fun hop_node_open(dbPath: String, secret: ByteArray?, secretLen: NativeLong, appSecret: ByteArray?, appSecretLen: NativeLong): Pointer?
    fun hop_node_open_keyed(dbPath: String, secret: ByteArray?, secretLen: NativeLong, appSecret: ByteArray?, appSecretLen: NativeLong, key: ByteArray?, keyLen: NativeLong): Pointer?
    fun hop_node_with_secret(secret: ByteArray?, secretLen: NativeLong): Pointer?
    fun hop_node_free(node: Pointer?)
    fun hop_node_address(node: Pointer?, out: ByteArray): Byte
    fun hop_node_tick(node: Pointer?, nowMs: Long)
    fun hop_publish_prekey(node: Pointer?): Byte
    fun hop_link_up(node: Pointer?, link: Long, role: Int)
    fun hop_bytes_received(node: Pointer?, link: Long, data: ByteArray?, len: NativeLong)
    fun hop_link_down(node: Pointer?, link: Long)
    fun hop_drain_outgoing(node: Pointer?, sink: DrainSink, ctx: Pointer?)
    fun hop_send_message(node: Pointer?, dst: ByteArray, contentType: String, body: ByteArray?, bodyLen: NativeLong, requestAck: Boolean, outId: ByteArray?): Byte
    fun hop_poll_inbox(node: Pointer?, sink: InboxSink, ctx: Pointer?)
    fun hop_accept_inbox(node: Pointer?, inboxId: ByteArray): Byte
    fun hop_message_status(node: Pointer?, id: ByteArray, relayed: IntByReference?, delivered: ByteByReference?, hops: ByteByReference?, ms: IntByReference?): Byte
    fun hop_address_to_base58(addr: ByteArray, out: ByteArray, outCap: NativeLong): NativeLong
    fun hop_address_from_base58(text: String, out32: ByteArray): Byte
    // D-wrappers: full hop.h parity - identity/status + the hops:// request/response surface.
    fun hop_abi_version(): Int
    fun hop_node_is_persistent(node: Pointer?): Byte
    fun hop_node_rehydrate_dropped(node: Pointer?): Int
    fun hop_node_secret(node: Pointer?, out: ByteArray): NativeLong
    fun hop_node_set_name(node: Pointer?, name: String)
    fun hop_is_secured(node: Pointer?, addr: ByteArray): Byte
    fun hop_subscribe(node: Pointer?, topic: String)
    fun hop_send_to(node: Pointer?, dst: ByteArray, contentType: String, body: ByteArray?, bodyLen: NativeLong, requestAck: Boolean, outId: ByteArray?): Byte
    fun hop_send_service_request(node: Pointer?, dst: ByteArray, service: String, method: String, args: ByteArray?, argsLen: NativeLong, outId: ByteArray?): Byte
    fun hop_send_service_response(node: Pointer?, to: ByteArray, forRequestId: ByteArray, status: Short, body: ByteArray?, bodyLen: NativeLong): Byte
    // §19 relay pool: the surface the v4 -> v5 ABI bump was taken for (PLAT-003). `out` for
    // hop_relay_next is a NUL-terminated C string buffer, so it marshals as a ByteArray like
    // hop_address_to_base58's; `out_available` is a `uintptr_t *`, hence NativeLongByReference.
    fun hop_relay_add(node: Pointer?, url: String, configured: Boolean): Byte
    fun hop_relay_next(node: Pointer?, out: ByteArray, outCap: NativeLong): NativeLong
    fun hop_relay_report(node: Pointer?, url: String, ok: Boolean)
    fun hop_relay_pool_size(node: Pointer?, outAvailable: NativeLongByReference?): NativeLong
    fun hop_poll_service_requests(node: Pointer?, sink: ServiceReqSink, ctx: Pointer?)
    fun hop_poll_service_responses(node: Pointer?, sink: ServiceRespSink, ctx: Pointer?)
    fun hop_accept_service_response(node: Pointer?, requestId: ByteArray): Byte
    // ---- section 32 hps:// pub/sub ------------------------------------------------------------
    //
    // The eighteen calls the v5 to v6 ABI bump was taken for. `uintptr_t` (a count, or a written
    // length) is NativeLong; `uint32_t` (an enum discriminant, a reach count) is Int; a `bool *`
    // out-param is ByteByReference for the same low-byte reason the bool RETURNS are Byte. A sink is
    // nullable wherever the C contract accepts NULL to just count, so a caller that only wants the
    // count never allocates a callback.
    fun hop_hps_register(node: Pointer?, path: String, kind: Int, access: Int, visibility: Int,
                         outPubkey: ByteArray?, outPubkeyCap: NativeLong, outPubkeyLen: NativeLongByReference?): Byte
    fun hop_hps_subscribe(node: Pointer?, host: ByteArray, path: String, outId: ByteArray?): Byte
    fun hop_hps_publish(node: Pointer?, path: String, body: ByteArray?, bodyLen: NativeLong, outId: ByteArray?): Byte
    fun hop_poll_hps_messages(node: Pointer?, sink: HpsMessageSink, ctx: Pointer?)
    fun hop_accept_hps_message(node: Pointer?, id: ByteArray): Byte
    fun hop_hps_invite(node: Pointer?, path: String, dest: ByteArray, outId: ByteArray?): Byte
    fun hop_hps_accept_invite(node: Pointer?, host: ByteArray, path: String, outId: ByteArray?): Byte
    fun hop_hps_decline_invite(node: Pointer?, host: ByteArray, path: String): Byte
    fun hop_poll_hps_invites(node: Pointer?, sink: HpsInviteSink, ctx: Pointer?)
    fun hop_hps_leave(node: Pointer?, path: String, outId: ByteArray?, outHasId: ByteByReference?): Byte
    fun hop_hps_pending(node: Pointer?, path: String, sink: HpsAddrSink?, ctx: Pointer?): NativeLong
    fun hop_hps_approve(node: Pointer?, path: String, requester: ByteArray, outId: ByteArray?): Byte
    fun hop_hps_deny(node: Pointer?, path: String, requester: ByteArray): Byte
    fun hop_hps_rekey(node: Pointer?, path: String, newPath: String, remove: ByteArray?, removeCount: NativeLong,
                      sink: HpsIdSink?, ctx: Pointer?): NativeLong
    fun hop_hps_reach(node: Pointer?, path: String): Int
    fun hop_hps_members(node: Pointer?, path: String, sink: HpsAddrSink?, ctx: Pointer?): NativeLong
    fun hop_hps_my_topics(node: Pointer?, sink: HpsTopicSink?, ctx: Pointer?): NativeLong
    fun hop_hps_browse(node: Pointer?, sink: HpsTopicInfoSink?, ctx: Pointer?): NativeLong
}

/** Read a JNA byte-width C `bool` return: libhop returns 0/1 in the low byte; any non-zero is true.
 *  See the bool-return note on [CHop] for why these natives return [Byte] rather than Boolean. */
private fun Byte.toBool(): Boolean = this != 0.toByte()

/** Guard an address/bundle-id argument handed to a native call.
 *
 *  Every `hop_*` function that takes an address, bundle id, or request id (dst / addr / id / to /
 *  for_request_id) reads EXACTLY 32 bytes from the pointer regardless of the Kotlin array's length: a
 *  shorter array makes native code read out of bounds (undefined behavior - a crash or leaked adjacent
 *  heap), and a longer one is silently truncated to its first 32 bytes. So validate the length here and
 *  fail loudly (IllegalArgumentException) instead of handing native code a mis-sized buffer - exactly
 *  as [HopAddress.base58] already does for its address argument. Returns the array for call-site chaining. */
private fun require32(bytes: ByteArray, name: String): ByteArray {
    require(bytes.size == HopAddress.ADDRESS_LEN) {
        "$name must be ${HopAddress.ADDRESS_LEN} bytes, got ${bytes.size}"
    }
    return bytes
}

/// Expected libhop ABI version (mirrors HOP_ABI_VERSION in hop.h). Asserted at load so a wrapper
/// built against a newer header fails loudly instead of drifting (F-28).
const val HOP_ABI_VERSION = 6

/** hops:// request callback (D-wrappers), one per queued inbound request during pollServiceRequests. */
internal fun interface ServiceReqSink : Callback {
    fun invoke(ctx: Pointer?, from: Pointer?, requestId: Pointer?, service: String?, method: String?, args: Pointer?, argsLen: NativeLong)
}

/** hops:// response callback (D-wrappers), one per queued inbound response during pollServiceResponses. */
internal fun interface ServiceRespSink : Callback {
    fun invoke(ctx: Pointer?, from: Pointer?, forRequestId: Pointer?, status: Short, body: Pointer?, bodyLen: NativeLong): Byte
}

/** A hops:// request delivered to this node acting as a service.
 *  Ownership: the ByteArray fields are owned, freshly-allocated snapshots (see [HopMessage]); treat
 *  them as read-only and use the `*Copy()` accessors before handing the bytes to code that might
 *  mutate them. equals/hashCode are content-based (value semantics); as with any value carrying a
 *  mutable array, do not mutate a field and then rely on it as a HashMap/HashSet key. */
data class HopServiceRequest(val from: ByteArray, val requestId: ByteArray, val service: String, val method: String, val args: ByteArray) {
    /** Defensive copies (mutate freely without affecting the request). */
    fun fromCopy(): ByteArray = from.copyOf()
    fun requestIdCopy(): ByteArray = requestId.copyOf()
    fun argsCopy(): ByteArray = args.copyOf()

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is HopServiceRequest) return false
        return from.contentEquals(other.from) && requestId.contentEquals(other.requestId) &&
            service == other.service && method == other.method && args.contentEquals(other.args)
    }
    override fun hashCode(): Int {
        var r = from.contentHashCode()
        r = 31 * r + requestId.contentHashCode()
        r = 31 * r + service.hashCode()
        r = 31 * r + method.hashCode()
        r = 31 * r + args.contentHashCode()
        return r
    }
}

/** A hops:// response delivered to this node acting as a caller.
 *  Ownership: the ByteArray fields are owned, freshly-allocated snapshots (see [HopMessage]); treat
 *  them as read-only and use the `*Copy()` accessors before handing the bytes to code that might
 *  mutate them. equals/hashCode are content-based (value semantics); as with any value carrying a
 *  mutable array, do not mutate a field and then rely on it as a HashMap/HashSet key. */
data class HopServiceResponse(val from: ByteArray, val forRequestId: ByteArray, val status: Int, val body: ByteArray) {
    /** Defensive copies (mutate freely without affecting the response). */
    fun fromCopy(): ByteArray = from.copyOf()
    fun forRequestIdCopy(): ByteArray = forRequestId.copyOf()
    fun bodyCopy(): ByteArray = body.copyOf()

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is HopServiceResponse) return false
        return from.contentEquals(other.from) && forRequestId.contentEquals(other.forRequestId) &&
            status == other.status && body.contentEquals(other.body)
    }
    override fun hashCode(): Int {
        var r = from.contentHashCode()
        r = 31 * r + forRequestId.contentHashCode()
        r = 31 * r + status
        r = 31 * r + body.contentHashCode()
        return r
    }
}

// ---- §32 hps:// value types ---------------------------------------------------------------------
//
// Ownership, identically to [HopMessage]: every ByteArray here is a freshly-allocated snapshot taken
// inside the callback (the native pointers are valid only for that call), owned by this value and
// never aliased to a libhop buffer. They are still mutable arrays a downstream caller could scribble
// on, so treat them as read-only and use the `*Copy()` accessors when handing bytes to code that
// might mutate them; a `data class` cannot copy from its generated accessors. equals/hashCode are
// content-based, so do not mutate a field and then rely on the value as a HashMap/HashSet key.

/** One received `hps://` publication: a single content-key-encrypted, per-writer-signed publication
 *  that was flooded once, NOT a per-member fan-out and not a multicast bundle.
 *
 *  [sender] is the VERIFIED writer for a channel and the host for a service. [id] is the queue id to
 *  hand back to [HopNode.acceptHpsMessage]: until it is accepted this publication is redelivered. */
data class HopHpsMessage(val id: ByteArray, val path: String, val sender: ByteArray, val body: ByteArray) {
    /** Defensive copies (mutate freely without affecting the publication). */
    fun idCopy(): ByteArray = id.copyOf()
    fun senderCopy(): ByteArray = sender.copyOf()
    fun bodyCopy(): ByteArray = body.copyOf()

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is HopHpsMessage) return false
        return id.contentEquals(other.id) && path == other.path &&
            sender.contentEquals(other.sender) && body.contentEquals(other.body)
    }
    override fun hashCode(): Int {
        var r = id.contentHashCode()
        r = 31 * r + path.hashCode()
        r = 31 * r + sender.contentHashCode()
        r = 31 * r + body.contentHashCode()
        return r
    }
}

/** An invite to a topic hosted by [host]. Draining invites is take-and-clear, not accept-to-remove:
 *  an invite the host surfaces and does not persist is GONE, so persist what you show. */
data class HopHpsInvite(val host: ByteArray, val path: String, val kind: HpsKind) {
    /** A defensive copy of the inviting host's address. */
    fun hostCopy(): ByteArray = host.copyOf()

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is HopHpsInvite) return false
        return host.contentEquals(other.host) && path == other.path && kind == other.kind
    }
    override fun hashCode(): Int {
        var r = host.contentHashCode()
        r = 31 * r + path.hashCode()
        r = 31 * r + kind.hashCode()
        return r
    }
}

/** A topic this node hosts ([hosting] true) or follows, as the node persisted it. This is what an app
 *  rebuilds its channel list from after a restart: the node keeps the topics, the app's in-memory list
 *  does not. */
data class HopHpsTopic(val host: ByteArray, val path: String, val kind: HpsKind, val hosting: Boolean,
                       val access: HpsAccess) {
    /** A defensive copy of the hosting node's address. */
    fun hostCopy(): ByteArray = host.copyOf()

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is HopHpsTopic) return false
        return host.contentEquals(other.host) && path == other.path && kind == other.kind &&
            hosting == other.hosting && access == other.access
    }
    override fun hashCode(): Int {
        var r = host.contentHashCode()
        r = 31 * r + path.hashCode()
        r = 31 * r + kind.hashCode()
        r = 31 * r + hosting.hashCode()
        r = 31 * r + access.hashCode()
        return r
    }
}

/** A discoverable topic seen on the mesh. The descriptor is encrypted to the app secret, so this only
 *  ever surfaces topics from the same app fabric; [access] is what joining it would cost. */
data class HopHpsTopicInfo(val host: ByteArray, val path: String, val kind: HpsKind, val title: String,
                           val summary: String, val access: HpsAccess) {
    /** A defensive copy of the hosting node's address. */
    fun hostCopy(): ByteArray = host.copyOf()

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is HopHpsTopicInfo) return false
        return host.contentEquals(other.host) && path == other.path && kind == other.kind &&
            title == other.title && summary == other.summary && access == other.access
    }
    override fun hashCode(): Int {
        var r = host.contentHashCode()
        r = 31 * r + path.hashCode()
        r = 31 * r + kind.hashCode()
        r = 31 * r + title.hashCode()
        r = 31 * r + summary.hashCode()
        r = 31 * r + access.hashCode()
        return r
    }
}

/** The outcome of leaving a topic. [id] is null when there was no leave bundle to send, which is what
 *  leaving a topic we HOST does: a success with no id, not a failure. Only [ok] false is a failure. */
data class HopHpsLeave(val ok: Boolean, val id: ByteArray?) {
    /** A defensive copy of the leave bundle id, or null when there was none. */
    fun idCopy(): ByteArray? = id?.copyOf()

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is HopHpsLeave) return false
        if (ok != other.ok) return false
        val mine = id
        val theirs = other.id
        return if (mine == null || theirs == null) mine == null && theirs == null else mine.contentEquals(theirs)
    }
    override fun hashCode(): Int = 31 * ok.hashCode() + (id?.contentHashCode() ?: 0)
}

/** Outbound-drain callback: invoked once per queued packet during `drainOutgoing`. */
internal fun interface DrainSink : Callback {
    fun invoke(ctx: Pointer?, link: Long, bytes: Pointer?, len: NativeLong)
}

/** Inbox callback: invoked once per received message during `pollInbox`. */
internal fun interface InboxSink : Callback {
    fun invoke(ctx: Pointer?, inboxId: Pointer?, from: Pointer?, contentType: String?, body: Pointer?, bodyLen: NativeLong, hops: Byte, createdAt: Long): Byte
}

// ---- §32 hps:// callbacks -----------------------------------------------------------------------
//
// A callback's `bool` RETURN is Byte for the reason spelled out on [CHop], and a `bool` ARGUMENT
// (my_topics' `hosting`) is Byte for the same reason read in the other direction: libffi then reads
// exactly the low byte instead of a full-width int whose upper bits the C ABI never promised to zero.
// `uint32_t` discriminants arrive as Int and are decoded with [hpsKindOf] / [hpsAccessOf].

/** Publication callback: one call per queued publication during `pollHpsMessages`. Returning 1 is
 *  synchronous acceptance (core durably removes it); 0 leaves it queued for redelivery. */
internal fun interface HpsMessageSink : Callback {
    fun invoke(ctx: Pointer?, id: Pointer?, path: String?, sender: Pointer?, body: Pointer?, bodyLen: NativeLong): Byte
}

/** Invite callback: one call per invite during `pollHpsInvites`, which CLEARS the queue as it drains. */
internal fun interface HpsInviteSink : Callback {
    fun invoke(ctx: Pointer?, host: Pointer?, path: String?, kind: Int)
}

/** Address callback: one call per pending requester (`hpsPending`) or retained member (`hpsMembers`). */
internal fun interface HpsAddrSink : Callback {
    fun invoke(ctx: Pointer?, addr: Pointer?)
}

/** Bundle-id callback: one call per rekey bundle sealed by `hpsRekey`. Same C shape as [HpsAddrSink],
 *  kept separate because what it carries is a bundle id and not a member address. */
internal fun interface HpsIdSink : Callback {
    fun invoke(ctx: Pointer?, id: Pointer?)
}

/** Topic callback: one call per hosted-or-followed topic during `hpsMyTopics`. */
internal fun interface HpsTopicSink : Callback {
    fun invoke(ctx: Pointer?, host: Pointer?, path: String?, kind: Int, hosting: Byte, access: Int)
}

/** Discovery callback: one call per discoverable topic during `hpsBrowse`. */
internal fun interface HpsTopicInfoSink : Callback {
    fun invoke(ctx: Pointer?, host: Pointer?, path: String?, kind: Int, title: String?, summary: String?, access: Int)
}

/** One owner for native handle acquisition, calls, reentrant callbacks, and destruction. */
internal class NativeHandleLifecycle(
    raw: Pointer,
    private val freeNative: (Pointer) -> Unit,
) : Runnable {
    private val lock = ReentrantLock(true)
    private var pointer: Pointer? = raw
    private var closed = false
    private var activeCalls = 0

    fun <T> call(block: (Pointer) -> T): T = lock.withLock {
        check(!closed) { "HopNode used after close()" }
        val handle = checkNotNull(pointer) { "HopNode used after close()" }
        activeCalls += 1
        try {
            block(handle)
        } finally {
            activeCalls -= 1
            if (closed && activeCalls == 0) freeLocked()
        }
    }

    fun close() = lock.withLock {
        if (closed) return@withLock
        closed = true
        if (activeCalls == 0) freeLocked()
    }

    override fun run() = close()

    private fun freeLocked() {
        val handle = pointer ?: return
        pointer = null
        freeNative(handle)
    }
}

/** A running Hop node. Owns the libhop handle.
 *
 * `AutoCloseable` with one reentrant lifecycle owner around every native call and free. A concurrent
 * close waits for an active call; a close from a synchronous C callback marks the node closed and
 * defers free until that outer call returns. A `Cleaner` is the dropped-without-close backstop.
 */
class HopNode private constructor(rawPtr: Pointer) : AutoCloseable {
    private val lifecycle = NativeHandleLifecycle(rawPtr) { C.hop_node_free(it) }
    private val cleanable = cleaner.register(this, lifecycle)

    private fun <T> native(block: (Pointer) -> T): T = lifecycle.call(block)

    /** Frees the native node. Idempotent; safe to call more than once. */
    override fun close() {
        lifecycle.close()
        cleanable.clean()
    }

    companion object {
        internal val C: CHop = Native.load("hop", CHop::class.java)
        private val cleaner: java.lang.ref.Cleaner = java.lang.ref.Cleaner.create()

        init {
            // F-28: fail loudly if the loaded libhop's ABI doesn't match what this wrapper was built for.
            val v = C.hop_abi_version()
            require(v == HOP_ABI_VERSION) { "libhop ABI mismatch: wrapper expects $HOP_ABI_VERSION, library is $v" }
        }

        fun ephemeral(): HopNode = HopNode(C.hop_node_new() ?: error("hop_node_new returned null"))

        /** Restore from a saved 32-byte identity [secret] (empty = fresh) with ephemeral (in-memory)
         *  storage. Mirrors Swift `HopNode.with(secret:)`. */
        fun withSecret(secret: ByteArray): HopNode =
            HopNode(C.hop_node_with_secret(secret, NativeLong(secret.size.toLong()))
                ?: error("hop_node_with_secret returned null"))

        /** Open with persistent storage at [dbPath], a saved 32-byte [secret] (empty = fresh), and an
         *  [appSecret] (empty = open fabric). Null only on a NULL/invalid path. */
        fun open(dbPath: String, secret: ByteArray = ByteArray(0), appSecret: ByteArray = ByteArray(0)): HopNode? =
            C.hop_node_open(dbPath, secret, NativeLong(secret.size.toLong()), appSecret, NativeLong(appSecret.size.toLong()))
                ?.let { HopNode(it) }

        /** Open with SQLCipher encryption at rest, keyed by a raw [key] from the Keystore (F-25). */
        fun openKeyed(dbPath: String, key: ByteArray, secret: ByteArray = ByteArray(0), appSecret: ByteArray = ByteArray(0)): HopNode? =
            C.hop_node_open_keyed(dbPath, secret, NativeLong(secret.size.toLong()), appSecret, NativeLong(appSecret.size.toLong()),
                                  key, NativeLong(key.size.toLong()))
                ?.let { HopNode(it) }
    }

    fun address(): ByteArray = native { handle -> ByteArray(32).also { C.hop_node_address(handle, it) } }
    fun tick(nowMs: Long) = native { handle -> C.hop_node_tick(handle, nowMs) }
    fun publishPrekey(): Boolean = native { handle -> C.hop_publish_prekey(handle).toBool() }

    // ---- §19 relay pool ----------------------------------------------------------------------
    //
    // PLAT-003: the four calls the v4 -> v5 ABI bump was taken for. No C-ABI wrapper bound them, so
    // an SDK-only host had no way to reach the pool and was stuck retrying one fixed relay URL
    // forever, which is the failure §19 exists to remove. tools/codegen/check-abi-version.sh now
    // fails if a wrapper pinned to an ABI level stops binding the calls that level's note names.

    /** Offer a relay endpoint to the pool. [configured] marks an operator/user choice, which a
     *  gossiped endpoint can never demote. Returns true if the endpoint is now pooled. */
    fun relayAdd(url: String, configured: Boolean = true): Boolean = native { handle ->
        C.hop_relay_add(handle, url, configured).toBool()
    }

    /** The relay to dial right now, or null when there is nothing dialable.
     *
     *  null with a non-zero [relayPool] total is the degraded "every candidate is backed off" state:
     *  WAIT and retry, do not report the node offline. null with a zero total is an empty pool. The
     *  2 KiB buffer is far past any real endpoint URL; the C call writes nothing and returns 0 if a
     *  URL would not fit, which surfaces here as "nothing to dial". */
    fun relayNext(): String? = native { handle ->
        val out = ByteArray(2048)
        val n = C.hop_relay_next(handle, out, NativeLong(out.size.toLong())).toInt()
        if (n > 0) String(out, 0, n, Charsets.UTF_8) else null
    }

    /** Report a dial outcome so the pool can score it. A success clears that endpoint's failure
     *  history; failures back it off exponentially and always eventually recover. */
    fun relayReport(url: String, ok: Boolean) = native { handle -> C.hop_relay_report(handle, url, ok) }

    /** Pooled endpoint counts: total known, and how many are dialable right now. */
    fun relayPool(): HopRelayPool = native { handle ->
        val available = NativeLongByReference()
        val total = C.hop_relay_pool_size(handle, available).toInt()
        HopRelayPool(total = total, available = available.value.toInt())
    }

    fun linkUp(link: Long, role: HopRole) = native { handle -> C.hop_link_up(handle, link, role.c) }
    fun linkDown(link: Long) = native { handle -> C.hop_link_down(handle, link) }
    fun bytesReceived(link: Long, bytes: ByteArray) = native { handle ->
        C.hop_bytes_received(handle, link, bytes, NativeLong(bytes.size.toLong()))
    }

    fun drainOutgoing(sink: (Long, ByteArray) -> Unit) {
        native { handle ->
            C.hop_drain_outgoing(handle, DrainSink { _, link, bytes, len ->
                sink(link, bytes?.getByteArray(0, len.toInt()) ?: ByteArray(0))
            }, null)
        }
    }

    /** Send an untraceable (§39) HDP datagram. Returns the 32-byte bundle id, or null on error. */
    fun send(dst: ByteArray, contentType: String = "text/plain", body: ByteArray, requestAck: Boolean = false): ByteArray? {
        require32(dst, "dst")
        val id = ByteArray(32)
        return native { handle ->
            if (C.hop_send_message(handle, dst, contentType, body, NativeLong(body.size.toLong()), requestAck, id).toBool()) id else null
        }
    }

    /** Poll durable messages without accepting them. Items repeat until [acceptInbox] succeeds. */
    fun pollInbox(sink: (HopMessage) -> Unit) {
        pollInboxAccepting { message ->
            sink(message)
            false
        }
    }

    /** Poll durable inbox items, accepting each only when [sink] returns true. */
    fun pollInboxAccepting(sink: (HopMessage) -> Boolean) {
        native { handle ->
            C.hop_poll_inbox(handle, InboxSink { _, inboxId, from, ct, body, blen, hops, created ->
                val accepted = sink(HopMessage(
                    from = from?.getByteArray(0, 32) ?: ByteArray(32),
                    contentType = ct ?: "",
                    body = body?.getByteArray(0, blen.toInt()) ?: ByteArray(0),
                    hops = hops.toUByte(), createdAt = created,
                    id = inboxId?.getByteArray(0, 32) ?: ByteArray(32)))
                if (accepted) 1 else 0
            }, null)
        }
    }

    /** Durably accept one item returned by [pollInbox]. The id must be exactly 32 bytes. */
    fun acceptInbox(id: ByteArray): Boolean =
        native { handle -> C.hop_accept_inbox(handle, require32(id, "inbox id")).toBool() }

    fun delivered(id: ByteArray): Boolean = status(id).delivered

    /** Full delivery status of a message we sent (relayed-count / delivered / forward hops+latency).
     *  Mirrors Swift `status(of:)`; reads every hop_message_status out-param, not just `delivered`. */
    fun status(id: ByteArray): HopStatus {
        require32(id, "id")
        val relayed = IntByReference()
        val delivered = ByteByReference()
        val hops = ByteByReference()
        val ms = IntByReference()
        native { handle -> C.hop_message_status(handle, id, relayed, delivered, hops, ms) }
        return HopStatus(
            relayed = relayed.value,
            delivered = delivered.value.toInt() != 0,
            forwardHops = hops.value.toUByte(),
            forwardMs = ms.value,
        )
    }

    // ---- D-wrappers: identity/status + the hops:// request/response surface (hop.h parity) ----

    /** Whether this node has durable storage (false ⇒ ephemeral fallback; F-26). */
    fun isPersistent(): Boolean = native { handle -> C.hop_node_is_persistent(handle).toBool() }

    /** How many persisted records failed to decode on startup (F-03); non-zero ⇒ state lost on upgrade. */
    fun rehydrateDropped(): Int = native { handle -> C.hop_node_rehydrate_dropped(handle) }

    /** Export this node's 32-byte identity secret (persist it in the Keystore). */
    fun secret(): ByteArray = native { handle -> ByteArray(32).also { C.hop_node_secret(handle, it) } }

    /** Set the display name reported via presence / hop.identify. */
    fun setName(name: String) = native { handle -> C.hop_node_set_name(handle, name) }

    /** Whether we hold a forward-secret session with `addr` (content is ratcheted, not static-sealed). */
    fun isSecured(addr: ByteArray): Boolean = native { handle ->
        C.hop_is_secured(handle, require32(addr, "addr")).toBool()
    }

    /** Subscribe to an hps:// topic. */
    fun subscribe(topic: String) = native { handle -> C.hop_subscribe(handle, topic) }

    /** Send a device-addressed (traced) message. Returns the bundle id, or null on error. */
    fun sendTo(dst: ByteArray, contentType: String = "text/plain", body: ByteArray, requestAck: Boolean = false): ByteArray? {
        require32(dst, "dst")
        val id = ByteArray(32)
        return native { handle ->
            if (C.hop_send_to(handle, dst, contentType, body, NativeLong(body.size.toLong()), requestAck, id).toBool()) id else null
        }
    }

    /** Send an hops:// service request. Returns the request id, or null on error. */
    fun sendServiceRequest(dst: ByteArray, service: String, method: String, args: ByteArray): ByteArray? {
        require32(dst, "dst")
        val id = ByteArray(32)
        return native { handle ->
            if (C.hop_send_service_request(handle, dst, service, method, args, NativeLong(args.size.toLong()), id).toBool()) id else null
        }
    }

    /** Reply to an hops:// service request. */
    fun sendServiceResponse(to: ByteArray, forRequestId: ByteArray, status: Int, body: ByteArray): Boolean {
        require32(to, "to")
        require32(forRequestId, "forRequestId")
        return native { handle ->
            C.hop_send_service_response(handle, to, forRequestId, status.toShort(), body, NativeLong(body.size.toLong())).toBool()
        }
    }

    /** Drain inbound hops:// requests addressed to this node (acting as a service). */
    fun pollServiceRequests(sink: (HopServiceRequest) -> Unit) {
        native { handle ->
            C.hop_poll_service_requests(handle, ServiceReqSink { _, from, reqId, service, method, args, alen ->
                sink(HopServiceRequest(
                    from = from?.getByteArray(0, 32) ?: ByteArray(32),
                    requestId = reqId?.getByteArray(0, 32) ?: ByteArray(32),
                    service = service ?: "", method = method ?: "",
                    args = args?.getByteArray(0, alen.toInt()) ?: ByteArray(0)))
            }, null)
        }
    }

    /** Poll inbound hops:// responses without accepting them. */
    fun pollServiceResponses(sink: (HopServiceResponse) -> Unit) {
        pollServiceResponsesAccepting { response ->
            sink(response)
            false
        }
    }

    /** Poll responses, accepting each only when [sink] returns true synchronously. */
    fun pollServiceResponsesAccepting(sink: (HopServiceResponse) -> Boolean) {
        native { handle ->
            C.hop_poll_service_responses(handle, ServiceRespSink { _, from, forId, status, body, blen ->
                val accepted = sink(HopServiceResponse(
                    from = from?.getByteArray(0, 32) ?: ByteArray(32),
                    forRequestId = forId?.getByteArray(0, 32) ?: ByteArray(32),
                    status = status.toInt() and 0xffff,
                    body = body?.getByteArray(0, blen.toInt()) ?: ByteArray(0)))
                if (accepted) 1 else 0
            }, null)
        }
    }

    /** Durably accept a previously-polled response by its 32-byte correlation request id. */
    fun acceptServiceResponse(forRequestId: ByteArray): Boolean = native { handle ->
        C.hop_accept_service_response(handle, require32(forRequestId, "request id")).toBool()
    }

    // ---- §32 hps:// pub/sub (services and channels) -------------------------------------------
    //
    // PLAT-005: the surface the v5 to v6 ABI bump was taken for. The protocol had shipped in both
    // UniFFI drivers for as long as it existed, but the C ABI exported none of it, so every wrapper
    // sitting on the C ABI (this one, Swift, and the React Native bridge above them) could not reach
    // group chat or channels AT ALL. tools/codegen/check-abi-version.sh now fails if a wrapper pinned
    // to an ABI level stops binding the calls that level's note names, because a version integer
    // confers no capability and binding the symbols does.
    //
    // The model, which is not the one a fan-out mental picture predicts: a publication is encrypted
    // ONCE to the topic's content key, signed by its writer, and flooded once. There is no
    // per-recipient copy and no per-recipient receipt, so [hpsReach] is the only honest delivery
    // number a UI can show, and membership, invites and revocation are all properties of the topic's
    // key handoff rather than of any addressed send.

    /** Host a topic at [path], minting and persisting its keys.
     *
     *  Returns the service public key, or null on failure. A SERVICE has one (only the owner
     *  broadcasts, signed by it); a CHANNEL has none (writers sign with their own identity), so a
     *  successfully hosted channel returns an EMPTY array. Those two cases are the reason the C call
     *  reports success in its return value and the key length separately, and the reason this must
     *  not be collapsed to null: an empty key is a hosted channel, null is nothing hosted at all.
     *
     *  Fails on an unknown/NULL path or an out-of-range discriminant, which the C ABI refuses rather
     *  than defaulting: reading a garbage access mode as OPEN would hand out the content key. */
    fun hpsRegister(path: String, kind: HpsKind, access: HpsAccess, visibility: HpsVisibility): ByteArray? {
        val key = ByteArray(32)
        val len = NativeLongByReference()
        return native { handle ->
            if (!C.hop_hps_register(handle, path, kind.c, access.c, visibility.c,
                                    key, NativeLong(key.size.toLong()), len).toBool()) {
                null
            } else {
                // Only the bytes native actually wrote. The C contract already refuses a key that
                // would not fit the capacity we passed, so a length past the buffer is a library bug
                // rather than a channel; surface that as a failure instead of a zero-padded key a
                // caller would otherwise trust as a service identity.
                val n = len.value.toInt()
                if (n < 0 || n > key.size) null else key.copyOf(n)
            }
        }
    }

    /** Subscribe to `hps://{host}/{path}`: seal a keys request to [host].
     *
     *  What happens next is the topic's access mode, not ours: an OPEN topic replies with the keys, a
     *  REQUEST_TO_JOIN topic queues us for the host's approval, and an INVITE topic ignores us
     *  entirely. Returns the 32-byte subscribe bundle id, or null on error. */
    fun hpsSubscribe(host: ByteArray, path: String): ByteArray? {
        require32(host, "host")
        val id = ByteArray(32)
        return native { handle -> if (C.hop_hps_subscribe(handle, host, path, id).toBool()) id else null }
    }

    /** Publish [body] to a topic we host or (for a channel) belong to: encrypted once to the content
     *  key, signed, and flooded once. Returns the 32-byte bundle id, or null for an unknown path, an
     *  over-long body, or no write access (a service only its owner may broadcast on). */
    fun hpsPublish(path: String, body: ByteArray): ByteArray? {
        val id = ByteArray(32)
        return native { handle ->
            if (C.hop_hps_publish(handle, path, body, NativeLong(body.size.toLong()), id).toBool()) id else null
        }
    }

    /** Poll received publications without accepting them. Items repeat until [acceptHpsMessage]
     *  succeeds, exactly like [pollInbox]: a host that dies between surfacing a post and persisting
     *  it must see the post again, or a channel silently loses it. */
    fun pollHpsMessages(sink: (HopHpsMessage) -> Unit) {
        pollHpsMessagesAccepting { message ->
            sink(message)
            false
        }
    }

    /** Poll publications, accepting each only when [sink] returns true synchronously. */
    fun pollHpsMessagesAccepting(sink: (HopHpsMessage) -> Boolean) {
        native { handle ->
            C.hop_poll_hps_messages(handle, HpsMessageSink { _, id, path, sender, body, blen ->
                val accepted = sink(HopHpsMessage(
                    id = id?.getByteArray(0, 32) ?: ByteArray(32),
                    path = path ?: "",
                    sender = sender?.getByteArray(0, 32) ?: ByteArray(32),
                    body = body?.getByteArray(0, blen.toInt()) ?: ByteArray(0)))
                if (accepted) 1 else 0
            }, null)
        }
    }

    /** Durably accept one publication returned by [pollHpsMessages]. The id must be exactly 32 bytes. */
    fun acceptHpsMessage(id: ByteArray): Boolean =
        native { handle -> C.hop_accept_hps_message(handle, require32(id, "hps message id")).toBool() }

    /** Host to destination: invite [dest] to a topic we host, the INVITE-mode key handoff. The invite
     *  arrives at [dest] via [pollHpsInvites]; keys are sealed only once it accepts. Returns the
     *  32-byte invite bundle id, or null on error. */
    fun hpsInvite(path: String, dest: ByteArray): ByteArray? {
        require32(dest, "dest")
        val id = ByteArray(32)
        return native { handle -> if (C.hop_hps_invite(handle, path, dest, id).toBool()) id else null }
    }

    /** Member to host: accept an invite we received, after which the host seals us the topic keys.
     *  Returns the 32-byte accept bundle id, or null on error. */
    fun hpsAcceptInvite(host: ByteArray, path: String): ByteArray? {
        require32(host, "host")
        val id = ByteArray(32)
        return native { handle -> if (C.hop_hps_accept_invite(handle, host, path, id).toBool()) id else null }
    }

    /** Decline a received invite. DURABLE: the invite is dropped from storage, so it does not
     *  reappear after a restart. */
    fun hpsDeclineInvite(host: ByteArray, path: String): Boolean = native { handle ->
        C.hop_hps_decline_invite(handle, require32(host, "host"), path).toBool()
    }

    /** Drain received invites, CLEARING them.
     *
     *  Unlike the publication queue this is take-and-clear, not accept-to-remove: an invite this
     *  callback surfaces is gone whether or not the host did anything with it, so persist what you
     *  surface before returning. */
    fun pollHpsInvites(sink: (HopHpsInvite) -> Unit) {
        native { handle ->
            C.hop_poll_hps_invites(handle, HpsInviteSink { _, host, path, kind ->
                sink(HopHpsInvite(
                    host = host?.getByteArray(0, 32) ?: ByteArray(32),
                    path = path ?: "",
                    kind = hpsKindOf(kind)))
            }, null)
        }
    }

    /** Leave a topic, so its host stops re-keying us on rotation.
     *
     *  [HopHpsLeave.id] is null when there was no bundle to send, which is what leaving a topic we
     *  HOST does: a success with no id. Only `ok == false` is a failure. */
    fun hpsLeave(path: String): HopHpsLeave {
        val id = ByteArray(32)
        val hasId = ByteByReference()
        val ok = native { handle -> C.hop_hps_leave(handle, path, id, hasId).toBool() }
        return HopHpsLeave(ok = ok, id = if (ok && hasId.value.toBool()) id else null)
    }

    /** Host: the addresses queued for approval on a REQUEST_TO_JOIN topic. */
    fun hpsPending(path: String): List<ByteArray> {
        val out = ArrayList<ByteArray>()
        native { handle ->
            C.hop_hps_pending(handle, path, HpsAddrSink { _, addr ->
                out.add(addr?.getByteArray(0, 32) ?: ByteArray(32))
            }, null)
        }
        return out
    }

    /** Host: approve a pending requester, sealing them the topic keys. Returns the 32-byte keys
     *  bundle id, or null on error. */
    fun hpsApprove(path: String, requester: ByteArray): ByteArray? {
        require32(requester, "requester")
        val id = ByteArray(32)
        return native { handle -> if (C.hop_hps_approve(handle, path, requester, id).toBool()) id else null }
    }

    /** Host: deny a pending requester and drop the request. No keys are sealed. */
    fun hpsDeny(path: String, requester: ByteArray): Boolean = native { handle ->
        C.hop_hps_deny(handle, path, require32(requester, "requester")).toBool()
    }

    /** Host: selective forward rotation, which is how a member is REVOKED.
     *
     *  Mints a new content key and seals it to every retained member except the addresses in [remove];
     *  a removed member keeps only the dead key, so it can still read the history it already has and
     *  nothing published afterwards. There is no "delete the member" operation because there is no
     *  per-member copy to delete: revocation IS the key rotation. A non-empty [newPath] moves the
     *  topic. Returns one bundle id per rekey bundle sealed, empty on error. */
    fun hpsRekey(path: String, newPath: String = "", remove: List<ByteArray> = emptyList()): List<ByteArray> {
        // The C call reads remove_count * 32 bytes from one buffer, so the addresses are packed back
        // to back and the COUNT is passed, never the byte length. A mis-sized entry is rejected here
        // rather than shifting every later address by a few bytes and revoking the wrong members.
        val packed = ByteArray(remove.size * HopAddress.ADDRESS_LEN)
        remove.forEachIndexed { i, addr ->
            require32(addr, "remove[$i]").copyInto(packed, i * HopAddress.ADDRESS_LEN)
        }
        val ids = ArrayList<ByteArray>()
        native { handle ->
            C.hop_hps_rekey(handle, path, newPath, packed, NativeLong(remove.size.toLong()),
                HpsIdSink { _, id -> ids.add(id?.getByteArray(0, 32) ?: ByteArray(32)) }, null)
        }
        return ids
    }

    /** Host: a topic's reach, the number of distinct addresses that have acked a publication on it.
     *  A flood has no per-recipient receipt, so this is the only delivery number a UI can honestly
     *  show for a topic. 0 for an unknown path. */
    fun hpsReach(path: String): Int = native { handle -> C.hop_hps_reach(handle, path) }

    /** Host: the retained-member set for a topic (who a rotation would re-key). */
    fun hpsMembers(path: String): List<ByteArray> {
        val out = ArrayList<ByteArray>()
        native { handle ->
            C.hop_hps_members(handle, path, HpsAddrSink { _, addr ->
                out.add(addr?.getByteArray(0, 32) ?: ByteArray(32))
            }, null)
        }
        return out
    }

    /** Every topic this node hosts or follows, so an app can rebuild its channel list after a
     *  restart: the node persists the topics, the app's in-memory list does not. */
    fun hpsMyTopics(): List<HopHpsTopic> {
        val out = ArrayList<HopHpsTopic>()
        native { handle ->
            C.hop_hps_my_topics(handle, HpsTopicSink { _, host, path, kind, hosting, access ->
                out.add(HopHpsTopic(
                    host = host?.getByteArray(0, 32) ?: ByteArray(32),
                    path = path ?: "",
                    kind = hpsKindOf(kind),
                    hosting = hosting.toBool(),
                    access = hpsAccessOf(access)))
            }, null)
        }
        return out
    }

    /** Discoverable topics seen on the mesh. The descriptors are decrypted with the app secret, so
     *  this only ever surfaces topics from the same app fabric. */
    fun hpsBrowse(): List<HopHpsTopicInfo> {
        val out = ArrayList<HopHpsTopicInfo>()
        native { handle ->
            C.hop_hps_browse(handle, HpsTopicInfoSink { _, host, path, kind, title, summary, access ->
                out.add(HopHpsTopicInfo(
                    host = host?.getByteArray(0, 32) ?: ByteArray(32),
                    path = path ?: "",
                    kind = hpsKindOf(kind),
                    title = title ?: "",
                    summary = summary ?: "",
                    access = hpsAccessOf(access)))
            }, null)
        }
        return out
    }

    /** Deprecated: prefer `close()` / `.use { }`. Kept for source compatibility; now idempotent. */
    @Deprecated("Use close() or .use { } (AutoCloseable)", ReplaceWith("close()"))
    fun free() = close()
}

object HopAddress {
    /** A Hop address is exactly this many bytes; the C ABI reads exactly this from the pointer. */
    const val ADDRESS_LEN = 32

    /** Encode a [ADDRESS_LEN]-byte address as base58.
     *
     *  The C `hop_address_to_base58` ALWAYS reads exactly 32 bytes from the pointer regardless of the
     *  Kotlin array's length. A shorter array would read out of bounds in native code; a longer one
     *  would be silently truncated to its first 32 bytes. So validate the length here and fail loudly
     *  (IllegalArgumentException) instead of handing native code a mis-sized buffer. The 64-byte output
     *  buffer is always enough for a 32-byte address (base58 of 32 bytes is at most ~44 chars). */
    fun base58(addr: ByteArray): String {
        require(addr.size == ADDRESS_LEN) { "Hop address must be $ADDRESS_LEN bytes, got ${addr.size}" }
        val out = ByteArray(64)
        val n = HopNode.C.hop_address_to_base58(addr, out, NativeLong(out.size.toLong())).toInt()
        return if (n > 0) String(out, 0, n, Charsets.US_ASCII) else ""
    }
    /** Decode a base58 address string, or null if it isn't exactly a 32-byte address. */
    fun fromBase58(text: String): ByteArray? {
        val out = ByteArray(ADDRESS_LEN)
        return if (HopNode.C.hop_address_from_base58(text, out).toBool()) out else null
    }
}
