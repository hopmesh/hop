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
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/** Which side opened a bearer link (the Noise role). */
enum class HopRole(val c: Int) { DIALER(0), ACCEPTOR(1) }

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
    fun hop_poll_service_requests(node: Pointer?, sink: ServiceReqSink, ctx: Pointer?)
    fun hop_poll_service_responses(node: Pointer?, sink: ServiceRespSink, ctx: Pointer?)
    fun hop_accept_service_response(node: Pointer?, requestId: ByteArray): Byte
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
const val HOP_ABI_VERSION = 4

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

/** Outbound-drain callback: invoked once per queued packet during `drainOutgoing`. */
internal fun interface DrainSink : Callback {
    fun invoke(ctx: Pointer?, link: Long, bytes: Pointer?, len: NativeLong)
}

/** Inbox callback: invoked once per received message during `pollInbox`. */
internal fun interface InboxSink : Callback {
    fun invoke(ctx: Pointer?, inboxId: Pointer?, from: Pointer?, contentType: String?, body: Pointer?, bodyLen: NativeLong, hops: Byte, createdAt: Long): Byte
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
