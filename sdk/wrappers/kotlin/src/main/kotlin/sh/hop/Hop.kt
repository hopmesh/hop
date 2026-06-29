// Hop — the idiomatic Kotlin face of libhop's C ABI (hop.h), via JNA. Same role as the Swift `Hop`
// wrapper: a thin, type-safe shim over the generated C contract (so it can't drift). Android bearers
// and the app use this; on Android the same .so is loaded, here (host JVM) it's libhop_ffi.dylib.

package sh.hop

import com.sun.jna.Callback
import com.sun.jna.Library
import com.sun.jna.Native
import com.sun.jna.NativeLong
import com.sun.jna.Pointer
import com.sun.jna.ptr.ByteByReference
import com.sun.jna.ptr.IntByReference

/** Which side opened a bearer link (the Noise role). */
enum class HopRole(val c: Int) { DIALER(0), ACCEPTOR(1) }

/** A decrypted message delivered to this node. */
data class HopMessage(val from: ByteArray, val contentType: String, val body: ByteArray, val hops: Byte, val createdAt: Long)

/** The raw JNA binding — one function per `hop_*` symbol. Internal; callers use [HopNode]. */
internal interface CHop : Library {
    fun hop_node_new(): Pointer?
    fun hop_node_free(node: Pointer?)
    fun hop_node_address(node: Pointer?, out: ByteArray): Boolean
    fun hop_node_tick(node: Pointer?, nowMs: Long)
    fun hop_publish_prekey(node: Pointer?): Boolean
    fun hop_link_up(node: Pointer?, link: Long, role: Int)
    fun hop_bytes_received(node: Pointer?, link: Long, data: ByteArray?, len: NativeLong)
    fun hop_link_down(node: Pointer?, link: Long)
    fun hop_drain_outgoing(node: Pointer?, sink: DrainSink, ctx: Pointer?)
    fun hop_send_message(node: Pointer?, dst: ByteArray, contentType: String, body: ByteArray?, bodyLen: NativeLong, requestAck: Boolean, outId: ByteArray?): Boolean
    fun hop_poll_inbox(node: Pointer?, sink: InboxSink, ctx: Pointer?)
    fun hop_message_status(node: Pointer?, id: ByteArray, relayed: IntByReference?, delivered: ByteByReference?, hops: ByteByReference?, ms: IntByReference?): Boolean
    fun hop_address_to_base58(addr: ByteArray, out: ByteArray, outCap: NativeLong): NativeLong
    fun hop_address_from_base58(text: String, out32: ByteArray): Boolean
}

/** Outbound-drain callback: invoked once per queued packet during `drainOutgoing`. */
internal fun interface DrainSink : Callback {
    fun invoke(ctx: Pointer?, link: Long, bytes: Pointer?, len: NativeLong)
}

/** Inbox callback: invoked once per received message during `pollInbox`. */
internal fun interface InboxSink : Callback {
    fun invoke(ctx: Pointer?, from: Pointer?, contentType: String?, body: Pointer?, bodyLen: NativeLong, hops: Byte, createdAt: Long)
}

/** A running Hop node. Owns the libhop handle. */
class HopNode private constructor(internal val raw: Pointer) {
    companion object {
        internal val C: CHop = Native.load("hop_ffi", CHop::class.java)
        fun ephemeral(): HopNode = HopNode(C.hop_node_new() ?: error("hop_node_new returned null"))
    }

    fun address(): ByteArray = ByteArray(32).also { C.hop_node_address(raw, it) }
    fun tick(nowMs: Long) = C.hop_node_tick(raw, nowMs)
    fun publishPrekey(): Boolean = C.hop_publish_prekey(raw)

    fun linkUp(link: Long, role: HopRole) = C.hop_link_up(raw, link, role.c)
    fun linkDown(link: Long) = C.hop_link_down(raw, link)
    fun bytesReceived(link: Long, bytes: ByteArray) = C.hop_bytes_received(raw, link, bytes, NativeLong(bytes.size.toLong()))

    fun drainOutgoing(sink: (Long, ByteArray) -> Unit) {
        C.hop_drain_outgoing(raw, DrainSink { _, link, bytes, len ->
            sink(link, bytes?.getByteArray(0, len.toInt()) ?: ByteArray(0))
        }, null)
    }

    /** Send an untraceable (§39) HDP datagram. Returns the 32-byte bundle id, or null on error. */
    fun send(dst: ByteArray, contentType: String = "text/plain", body: ByteArray, requestAck: Boolean = false): ByteArray? {
        val id = ByteArray(32)
        return if (C.hop_send_message(raw, dst, contentType, body, NativeLong(body.size.toLong()), requestAck, id)) id else null
    }

    fun pollInbox(sink: (HopMessage) -> Unit) {
        C.hop_poll_inbox(raw, InboxSink { _, from, ct, body, blen, hops, created ->
            sink(HopMessage(
                from = from?.getByteArray(0, 32) ?: ByteArray(32),
                contentType = ct ?: "",
                body = body?.getByteArray(0, blen.toInt()) ?: ByteArray(0),
                hops = hops, createdAt = created))
        }, null)
    }

    fun delivered(id: ByteArray): Boolean {
        val d = ByteByReference()
        C.hop_message_status(raw, id, null, d, null, null)
        return d.value.toInt() != 0
    }

    fun free() = C.hop_node_free(raw)
}

object HopAddress {
    fun base58(addr: ByteArray): String {
        val out = ByteArray(64)
        val n = HopNode.C.hop_address_to_base58(addr, out, NativeLong(out.size.toLong())).toInt()
        return if (n > 0) String(out, 0, n, Charsets.US_ASCII) else ""
    }
    fun fromBase58(text: String): ByteArray? {
        val out = ByteArray(32)
        return if (HopNode.C.hop_address_from_base58(text, out)) out else null
    }
}
