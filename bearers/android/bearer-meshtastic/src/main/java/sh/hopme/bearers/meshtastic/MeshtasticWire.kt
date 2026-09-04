package sh.hopme.bearers.meshtastic

// MeshtasticWire: the Meshtastic bearer's PURE, Android-free wire logic, split out so it is unit-testable
// on a plain JVM (MeshtasticBearer.kt pulls in android.bluetooth.*, which does not load under a stubbed
// android.jar). This is the byte-for-byte twin of bearers/apple/HopBearerMeshtastic's MeshtasticWire.swift:
// the minimal Meshtastic protobuf codec, the fragment/reassembly layer that carries a Hop link frame across
// tiny LoRa packets, the Hop link-frame grammar (identical tags to the LAN/BLE bearers), and the dedup
// keep-rule. Apple <-> Android interop rides on these staying identical, which tools/meshtastic-parity.sh
// enforces against bearers/meshtastic-vectors.json.
//
// Hop link-frame grammar (same 1-byte tags as :bearer-lan):
//   HELLO 0x01 : [16B nodeId][1B role][1B flags]   role 1 = the greater-id side (Noise initiator)
//   PING  0x02 : [8B seq][8B nowMs]
//   PONG  0x03 : echoes the peer's PING body prefix
//   DATA  0x10 : the consumer's application bytes
//
// Fragment header prepended to each Meshtastic payload (4 bytes):
//   [msgId hi][msgId lo][fragIndex][fragCount]  then up to MESH_MAX_CHUNK bytes of the frame body

// ---- Pinned cross-platform constants (see bearers/meshtastic-vectors.json) ----------------------------

/** Meshtastic PortNum for Hop traffic (inside the PRIVATE_APP 256..511 range). */
internal const val MESH_HOP_PORTNUM = 260

/** Meshtastic PortNum.ADMIN_APP. Channel get/set rides this, never the Hop port. */
internal const val MESH_ADMIN_PORTNUM = 6

/** Meshtastic PortNum.ROUTING_APP. Unicast fragments set want_ack; NONE on this port is the radio ACK. */
internal const val MESH_ROUTING_PORTNUM = 5

/** Spray unacked unicast DATA/HELLO: first retry, doubling, cap. Tick is the bearer work period. */
internal const val MESH_SPRAY_INITIAL_MS = 2_000L
internal const val MESH_SPRAY_MULTIPLIER = 2
internal const val MESH_SPRAY_CAP_MS = 60_000L
internal const val MESH_SPRAY_TICK_MS = 1_000L
internal const val MESH_SPRAY_MAX_OUTSTANDING = 8

/** SECONDARY slot name Hop writes. Primary (index 0) is left to Meshtastic.app. */
internal const val MESH_HOP_CHANNEL_NAME = "Hop"

/** AES-128 PSK, hex 686f702e6d6573682e70736b2e763121 ("hop.mesh.psk.v1!"). Shared by every Hop node. */
internal const val MESH_HOP_CHANNEL_PSK_HEX = "686f702e6d6573682e70736b2e763121"
internal val MESH_HOP_CHANNEL_PSK = byteArrayOf(
    0x68, 0x6f, 0x70, 0x2e, 0x6d, 0x65, 0x73, 0x68,
    0x2e, 0x70, 0x73, 0x6b, 0x2e, 0x76, 0x31, 0x21,
)

/** ChannelSettings.id; ASCII 'HOP1' as 0x484F5031. */
internal const val MESH_HOP_CHANNEL_ID = 0x484F5031L

internal const val MESH_CHANNEL_ROLE_DISABLED = 0
internal const val MESH_CHANNEL_ROLE_SECONDARY = 2

/** Meshtastic MAX_NUM_CHANNELS. Index 0 is PRIMARY; Hop probes 1..7. */
internal const val MESH_MAX_CHANNELS = 8

/** The Meshtastic broadcast node address. */
internal const val MESH_BROADCAST_ADDR = 0xFFFFFFFFL

/** Max Hop bytes per Meshtastic packet (a Data.payload tops out near 237; 200 leaves header headroom). */
internal const val MESH_MAX_CHUNK = 200

/** Fragment header size: [msgId:2][fragIndex:1][fragCount:1]. */
internal const val MESH_FRAG_HEADER = 4

/** A frame is split across at most 255 fragments (fragCount is one byte). */
internal const val MESH_MAX_FRAGS = 255
internal const val MESH_MAX_MESSAGE = MESH_MAX_FRAGS * MESH_MAX_CHUNK

/** Liveness (LoRa is slow + duty-cycle limited): PING every 30 s, dead after 180 s of silence. */
internal const val MESH_PING_MS = 30_000L
internal const val MESH_DEAD_MS = 180_000L

/** Drop a half-assembled inbound message after this long; bound concurrent partials per peer. */
internal const val MESH_REASSEMBLY_TTL_MS = 120_000L
internal const val MESH_MAX_PARTIAL_PER_PEER = 8

// Hop link-frame type tags (hello/ping/pong/data identical to :bearer-lan).
internal const val M_HELLO = 0x01
internal const val M_PING = 0x02
internal const val M_PONG = 0x03
internal const val M_ACK = 0x04
internal const val M_DATA = 0x10

// ---- Minimal protobuf codec (only the Meshtastic messages the bearer needs) ---------------------------

/** A tiny protobuf writer: varint, fixed32, and length-delimited fields. Hand-encoding the exact subset
 *  the bearer needs is far lighter than pulling the generated Meshtastic SDK, and is fully unit-testable. */
internal class ProtoWriter {
    private val out = ArrayList<Byte>()

    fun varintField(field: Int, value: Long): ProtoWriter { tag(field, 0); varint(value); return this }

    fun fixed32Field(field: Int, value: Long): ProtoWriter {
        tag(field, 5)
        for (i in 0 until 4) out.add(((value ushr (8 * i)) and 0xff).toByte())   // little-endian
        return this
    }

    fun bytesField(field: Int, value: ByteArray): ProtoWriter {
        tag(field, 2); varint(value.size.toLong()); for (b in value) out.add(b); return this
    }

    fun toBytes(): ByteArray = out.toByteArray()

    private fun tag(field: Int, wire: Int) = varint(((field shl 3) or wire).toLong())

    private fun varint(v: Long) {
        var value = v
        do {
            var b = (value and 0x7f).toInt()
            value = value ushr 7
            if (value != 0L) b = b or 0x80
            out.add(b.toByte())
        } while (value != 0L)
    }
}

/** A tiny bounds-checked protobuf reader. Every read returns null on a malformed/truncated buffer, so a
 *  hostile radio frame can never index out of range. */
internal class ProtoReader(private val buf: ByteArray) {
    private var i = 0

    val atEnd: Boolean get() = i >= buf.size

    /** (fieldNumber, wireType) or null at end / on a truncated tag. */
    fun readTag(): Pair<Int, Int>? {
        val t = readVarint() ?: return null
        return Pair((t ushr 3).toInt(), (t and 0x7).toInt())
    }

    fun readVarint(): Long? {
        var result = 0L
        var shift = 0
        while (i < buf.size) {
            val b = buf[i].toInt() and 0xff; i++
            if (shift > 63) return null
            result = result or ((b.toLong() and 0x7f) shl shift)
            if (b and 0x80 == 0) return result
            shift += 7
        }
        return null
    }

    fun readFixed32(): Long? {
        if (i + 4 > buf.size) return null
        var v = 0L
        for (k in 0 until 4) v = v or ((buf[i + k].toLong() and 0xff) shl (8 * k))
        i += 4
        return v
    }

    fun readBytes(): ByteArray? {
        val len = readVarint()?.toInt() ?: return null
        if (len < 0 || i + len > buf.size) return null
        val out = buf.copyOfRange(i, i + len)
        i += len
        return out
    }

    /** Skip a field of the given wire type; false on a malformed buffer. */
    fun skip(wire: Int): Boolean = when (wire) {
        0 -> readVarint() != null
        1 -> if (i + 8 <= buf.size) { i += 8; true } else false
        2 -> readBytes() != null
        5 -> readFixed32() != null
        else -> false
    }
}

// ---- Meshtastic messages (the exact subset the bearer speaks) -----------------------------------------

/** What the bearer acts on after decoding one FromRadio: our node number, a neighbor, Hop data, or admin. */
internal sealed class MeshInbound {
    data class MyNodeNum(val num: Long) : MeshInbound()
    data class SeenNode(val num: Long) : MeshInbound()
    data class HopData(val from: Long, val payload: ByteArray) : MeshInbound() {
        override fun equals(other: Any?): Boolean =
            other is HopData && other.from == from && other.payload.contentEquals(payload)
        override fun hashCode(): Int = 31 * from.hashCode() + payload.contentHashCode()
    }
    data class Admin(val payload: ByteArray) : MeshInbound() {
        override fun equals(other: Any?): Boolean =
            other is Admin && other.payload.contentEquals(payload)
        override fun hashCode(): Int = payload.contentHashCode()
    }
    data class Routing(val requestId: Long, val error: Int) : MeshInbound()
}

/** One Meshtastic Channel (index + settings + role) from a get_channel_response. */
internal data class MeshChannel(
    val index: Int,
    val name: String,
    val psk: ByteArray,
    val role: Int,
) {
    val isHop: Boolean
        get() = name == MESH_HOP_CHANNEL_NAME && psk.contentEquals(MESH_HOP_CHANNEL_PSK)
    val isFree: Boolean
        get() = role == MESH_CHANNEL_ROLE_DISABLED
}

/** Decoded AdminMessage: the session passkey plus an optional Channel from get_channel_response. */
internal data class AdminInbound(val passkey: ByteArray, val channel: MeshChannel?)

internal object MeshtasticProto {
    // Field numbers from the stable Meshtastic mesh.proto (wire types matter):
    //   Data:          portnum=1 (varint), payload=2 (bytes)
    //   MeshPacket:    from=1 (fixed32), to=2 (fixed32), channel=3 (varint), decoded=4 (Data),
    //                  id=6 (fixed32), hop_limit=9 (varint)
    //   ToRadio:       packet=1 (MeshPacket), want_config_id=3 (varint)
    //   FromRadio:     packet=2 (MeshPacket), my_info=3 (MyNodeInfo)
    //   MyNodeInfo:    my_node_num=1 (varint)
    //   Channel:       index=1 (varint), settings=2 (ChannelSettings), role=3 (varint)
    //   ChannelSettings: psk=2 (bytes), name=3 (string), id=4 (fixed32)
    //   AdminMessage:  get_channel_request=1 (uint32, index+1), get_channel_response=2 (Channel),
    //                  set_channel=33 (Channel), session_passkey=101 (bytes)

    fun encodeData(payload: ByteArray, portnum: Long = MESH_HOP_PORTNUM.toLong()): ByteArray =
        ProtoWriter().varintField(1, portnum).bytesField(2, payload).toBytes()

    fun encodeToRadioPacket(
        from: Long, to: Long, id: Long, hopLimit: Int, fragment: ByteArray,
        portnum: Long = MESH_HOP_PORTNUM.toLong(),
        channel: Int = 0,
        wantAck: Boolean = false,
    ): ByteArray {
        val pkt = ProtoWriter().fixed32Field(1, from).fixed32Field(2, to)
        if (channel != 0) pkt.varintField(3, channel.toLong())
        val body = pkt.bytesField(4, encodeData(fragment, portnum))
            .fixed32Field(6, id)
            .varintField(9, hopLimit.toLong())
        if (wantAck) body.varintField(10, 1)
        return ProtoWriter().bytesField(1, body.toBytes()).toBytes()
    }

    fun encodeWantConfig(nonce: Long): ByteArray = ProtoWriter().varintField(3, nonce).toBytes()

    /** AdminMessage.get_channel_request. Firmware uses index+1 so 0 can mean "unset". */
    fun encodeGetChannelRequest(index: Int): ByteArray =
        ProtoWriter().varintField(1, (index + 1).toLong()).toBytes()

    fun encodeChannel(index: Int, name: String, psk: ByteArray, role: Int): ByteArray {
        val settings = ProtoWriter()
            .bytesField(2, psk)
            .bytesField(3, name.toByteArray(Charsets.UTF_8))
            .fixed32Field(4, MESH_HOP_CHANNEL_ID)
            .toBytes()
        return ProtoWriter()
            .varintField(1, index.toLong())
            .bytesField(2, settings)
            .varintField(3, role.toLong())
            .toBytes()
    }

    /** AdminMessage.set_channel of Hop's SECONDARY, with the required session_passkey. */
    fun encodeSetHopChannel(passkey: ByteArray, index: Int): ByteArray {
        val channel = encodeChannel(index, MESH_HOP_CHANNEL_NAME, MESH_HOP_CHANNEL_PSK, MESH_CHANNEL_ROLE_SECONDARY)
        val w = ProtoWriter().bytesField(33, channel)
        if (passkey.isNotEmpty()) w.bytesField(101, passkey)
        return w.toBytes()
    }

    /** AdminMessage.get_channel_response, for tests that drive the bearer without a radio. */
    fun encodeGetChannelResponse(passkey: ByteArray, index: Int, name: String, psk: ByteArray, role: Int): ByteArray {
        val w = ProtoWriter().bytesField(2, encodeChannel(index, name, psk, role))
        if (passkey.isNotEmpty()) w.bytesField(101, passkey)
        return w.toBytes()
    }

    fun encodeAdminToRadio(to: Long, id: Long, admin: ByteArray): ByteArray =
        encodeToRadioPacket(0L, to, id, 0, admin, MESH_ADMIN_PORTNUM.toLong(), 0)

    fun decodeFromRadio(bytes: ByteArray): MeshInbound? {
        val r = ProtoReader(bytes)
        while (true) {
            val (field, wire) = r.readTag() ?: return null
            when {
                field == 2 && wire == 2 -> {
                    val sub = r.readBytes() ?: return null
                    decodeMeshPacket(sub)?.let { return it }
                }
                field == 3 && wire == 2 -> {
                    val sub = r.readBytes() ?: return null
                    decodeMyNodeNum(sub)?.let { return MeshInbound.MyNodeNum(it) }
                }
                field == 4 && wire == 2 -> {
                    val sub = r.readBytes() ?: return null
                    decodeMyNodeNum(sub)?.let { return MeshInbound.SeenNode(it) }
                }
                else -> if (!r.skip(wire)) return null
            }
        }
    }

    fun decodeMeshPacket(bytes: ByteArray): MeshInbound? {
        val r = ProtoReader(bytes)
        var from = 0L
        var decoded: ByteArray? = null
        while (true) {
            val (field, wire) = r.readTag() ?: break
            when {
                field == 1 && wire == 5 -> from = r.readFixed32() ?: return null
                field == 4 && wire == 2 -> decoded = r.readBytes() ?: return null
                else -> if (!r.skip(wire)) return null
            }
        }
        val data = decoded ?: return null
        val (port, payload) = decodeData(data) ?: return null
        return when (port) {
            MESH_HOP_PORTNUM.toLong() -> MeshInbound.HopData(from, payload)
            MESH_ADMIN_PORTNUM.toLong() -> MeshInbound.Admin(payload)
            MESH_ROUTING_PORTNUM.toLong() -> decodeRouting(data)
            else -> null
        }
    }

    /** Data.request_id is fixed32 field 6; Routing.error_reason is varint field 3 of Data.payload. */
    fun decodeRouting(data: ByteArray): MeshInbound.Routing? {
        val r = ProtoReader(data)
        var port = -1L
        var payload: ByteArray? = null
        var requestId = 0L
        while (true) {
            val (field, wire) = r.readTag() ?: break
            when {
                field == 1 && wire == 0 -> port = r.readVarint() ?: return null
                field == 2 && wire == 2 -> payload = r.readBytes() ?: return null
                field == 6 && wire == 5 -> requestId = r.readFixed32() ?: return null
                else -> if (!r.skip(wire)) return null
            }
        }
        if (port != MESH_ROUTING_PORTNUM.toLong()) return null
        var error = 0
        if (payload != null) {
            val p = ProtoReader(payload)
            while (true) {
                val (field, wire) = p.readTag() ?: break
                when {
                    field == 3 && wire == 0 -> error = (p.readVarint() ?: return null).toInt()
                    else -> if (!p.skip(wire)) return null
                }
            }
        }
        return MeshInbound.Routing(requestId, error)
    }

    fun decodeData(bytes: ByteArray): Pair<Long, ByteArray>? {
        val r = ProtoReader(bytes)
        var portnum = -1L
        var payload: ByteArray? = null
        while (true) {
            val (field, wire) = r.readTag() ?: break
            when {
                field == 1 && wire == 0 -> portnum = r.readVarint() ?: return null
                field == 2 && wire == 2 -> payload = r.readBytes() ?: return null
                else -> if (!r.skip(wire)) return null
            }
        }
        if (portnum < 0) return null
        return Pair(portnum, payload ?: ByteArray(0))
    }

    /** The payload of a Data submessage IFF it is on the Hop port, else null. */
    fun decodeHopData(bytes: ByteArray): ByteArray? {
        val (port, payload) = decodeData(bytes) ?: return null
        return if (port == MESH_HOP_PORTNUM.toLong()) payload else null
    }

    fun decodeChannel(bytes: ByteArray): MeshChannel? {
        val r = ProtoReader(bytes)
        var index = 0
        var settings: ByteArray? = null
        var role = 0
        while (true) {
            val (field, wire) = r.readTag() ?: break
            when {
                field == 1 && wire == 0 -> index = (r.readVarint() ?: return null).toInt()
                field == 2 && wire == 2 -> settings = r.readBytes() ?: return null
                field == 3 && wire == 0 -> role = (r.readVarint() ?: return null).toInt()
                else -> if (!r.skip(wire)) return null
            }
        }
        var name = ""
        var psk = ByteArray(0)
        if (settings != null) {
            val s = ProtoReader(settings)
            while (true) {
                val (field, wire) = s.readTag() ?: break
                when {
                    field == 2 && wire == 2 -> psk = s.readBytes() ?: return null
                    field == 3 && wire == 2 -> name = String(s.readBytes() ?: return null, Charsets.UTF_8)
                    else -> if (!s.skip(wire)) return null
                }
            }
        }
        return MeshChannel(index, name, psk, role)
    }

    fun decodeAdminMessage(bytes: ByteArray): AdminInbound? {
        val r = ProtoReader(bytes)
        var passkey = ByteArray(0)
        var channel: MeshChannel? = null
        while (true) {
            val (field, wire) = r.readTag() ?: break
            when {
                field == 2 && wire == 2 -> {
                    val sub = r.readBytes() ?: return null
                    channel = decodeChannel(sub) ?: return null
                }
                field == 101 && wire == 2 -> passkey = r.readBytes() ?: return null
                else -> if (!r.skip(wire)) return null
            }
        }
        return AdminInbound(passkey, channel)
    }

    /** from + portnum of a FromRadio packet, or null. Used to log why a frame is not Hop. */
    fun peekPacketPort(bytes: ByteArray): Pair<Long, Long>? {
        val r = ProtoReader(bytes)
        while (true) {
            val (field, wire) = r.readTag() ?: return null
            if (field == 2 && wire == 2) {
                val sub = r.readBytes() ?: return null
                val p = ProtoReader(sub)
                var from = 0L
                var decoded: ByteArray? = null
                while (true) {
                    val (f, w) = p.readTag() ?: break
                    when {
                        f == 1 && w == 5 -> from = p.readFixed32() ?: return null
                        f == 4 && w == 2 -> decoded = p.readBytes() ?: return null
                        else -> if (!p.skip(w)) return null
                    }
                }
                val data = decoded ?: return Pair(from, -1L)
                val d = ProtoReader(data)
                var portnum = -1L
                while (true) {
                    val (f, w) = d.readTag() ?: break
                    when {
                        f == 1 && w == 0 -> portnum = d.readVarint() ?: return Pair(from, -1L)
                        else -> if (!d.skip(w)) return Pair(from, portnum)
                    }
                }
                return Pair(from, portnum)
            }
            if (!r.skip(wire)) return null
        }
    }

    fun decodeMyNodeNum(bytes: ByteArray): Long? {
        val r = ProtoReader(bytes)
        while (true) {
            val (field, wire) = r.readTag() ?: return null
            if (field == 1 && wire == 0) return r.readVarint()
            if (!r.skip(wire)) return null
        }
    }
}

// ---- Hop link-frame grammar (identical tags to :bearer-lan) --------------------------------------------

internal object MeshFrame {
    fun hello(myId: ByteArray, isGreater: Boolean): ByteArray =
        byteArrayOf(M_HELLO.toByte()) + myId + byteArrayOf((if (isGreater) 1 else 0).toByte(), 0)

    fun ping(seq: Long, nowMs: Long): ByteArray =
        byteArrayOf(M_PING.toByte()) + u64(seq) + u64(nowMs)

    fun pong(echo: ByteArray): ByteArray = byteArrayOf(M_PONG.toByte()) + echo

    fun data(payload: ByteArray): ByteArray = byteArrayOf(M_DATA.toByte()) + payload

    fun ack(msgId: Int): ByteArray = byteArrayOf(
        M_ACK.toByte(), ((msgId ushr 8) and 0xff).toByte(), (msgId and 0xff).toByte(),
    )

    fun ackMsgId(body: ByteArray): Int? {
        if (body.size < 3 || (body[0].toInt() and 0xff) != M_ACK) return null
        return ((body[1].toInt() and 0xff) shl 8) or (body[2].toInt() and 0xff)
    }

    /** The 16-byte peerId a HELLO body carries, or null if too short. */
    fun helloPeerId(body: ByteArray): ByteArray? = if (body.size >= 17) body.copyOfRange(1, 17) else null

    fun u64(v: Long): ByteArray = ByteArray(8) { (v ushr (56 - it * 8)).toByte() }

    fun u64dec(b: ByteArray, o: Int): Long {
        var v = 0L
        for (k in 0..7) if (o + k < b.size) v = (v shl 8) or (b[o + k].toLong() and 0xff)
        return v
    }
}

// ---- Fragmentation + reassembly ------------------------------------------------------------------------

/** Split a Hop link-frame body into fragments that each fit one Meshtastic packet, prefixed with
 *  [msgId:2][fragIndex:1][fragCount:1]. An empty body yields ONE empty fragment. Null if the body exceeds
 *  MESH_MAX_MESSAGE. */
internal fun meshFragment(body: ByteArray, msgId: Int): List<ByteArray>? {
    if (body.size > MESH_MAX_MESSAGE) return null
    val count = if (body.isEmpty()) 1 else (body.size + MESH_MAX_CHUNK - 1) / MESH_MAX_CHUNK
    if (count > MESH_MAX_FRAGS) return null
    val out = ArrayList<ByteArray>(count)
    for (idx in 0 until count) {
        val start = idx * MESH_MAX_CHUNK
        val end = minOf(start + MESH_MAX_CHUNK, body.size)
        val header = byteArrayOf(
            ((msgId ushr 8) and 0xff).toByte(), (msgId and 0xff).toByte(), idx.toByte(), count.toByte(),
        )
        out.add(if (start < end) header + body.copyOfRange(start, end) else header)
    }
    return out
}

/** The parsed header of one inbound fragment, or null for a runt / inconsistent header. */
internal class MeshFragHeader private constructor(
    val msgId: Int,
    val index: Int,
    val count: Int,
    val chunk: ByteArray,
) {
    companion object {
        fun parse(frag: ByteArray): MeshFragHeader? {
            if (frag.size < MESH_FRAG_HEADER) return null
            val id = ((frag[0].toInt() and 0xff) shl 8) or (frag[1].toInt() and 0xff)
            val idx = frag[2].toInt() and 0xff
            val cnt = frag[3].toInt() and 0xff
            if (cnt < 1 || cnt > MESH_MAX_FRAGS || idx >= cnt) return null
            return MeshFragHeader(id, idx, cnt, frag.copyOfRange(MESH_FRAG_HEADER, frag.size))
        }
    }
}

/** Completed reassembly: the Hop fragment msgId (needed for M_ACK) plus the frame body. */
internal data class MeshComplete(val msgId: Int, val body: ByteArray)

/** Per-peer reassembly of fragmented Hop frames, keyed by (peer node num, msgId). Pure: the caller supplies
 *  `nowMs` so it is deterministically testable with no clock. Not thread-safe; the bearer owns it on its
 *  single work thread (mirroring the Apple bearer's serial queue). */
internal class MeshReassembler {
    private class Partial(val count: Int, val firstSeenMs: Long) {
        val chunks = HashMap<Int, ByteArray>()
    }

    // node num -> msgId -> Partial
    private val partials = HashMap<Long, HashMap<Int, Partial>>()

    fun accept(peer: Long, fragment: ByteArray, nowMs: Long): MeshComplete? {
        val h = MeshFragHeader.parse(fragment) ?: return null
        evictStale(nowMs)
        val byId = partials.getOrPut(peer) { HashMap() }

        if (h.count == 1) {
            if (byId.isEmpty()) partials.remove(peer)
            return MeshComplete(h.msgId, h.chunk)
        }

        var p = byId[h.msgId]
        if (p == null || p.count != h.count) { p = Partial(h.count, nowMs); byId[h.msgId] = p }
        p.chunks[h.index] = h.chunk

        if (byId.size > MESH_MAX_PARTIAL_PER_PEER) {
            byId.minByOrNull { it.value.firstSeenMs }?.key?.let { byId.remove(it) }
        }

        if (p.chunks.size != p.count) return null

        val body = ArrayList<Byte>()
        for (idx in 0 until p.count) p.chunks[idx]?.forEach { body.add(it) }
        byId.remove(h.msgId)
        if (byId.isEmpty()) partials.remove(peer)
        return MeshComplete(h.msgId, body.toByteArray())
    }

    fun evictStale(nowMs: Long) {
        val deadPeers = ArrayList<Long>()
        for ((peer, byId) in partials) {
            byId.entries.removeAll { nowMs - it.value.firstSeenMs > MESH_REASSEMBLY_TTL_MS }
            if (byId.isEmpty()) deadPeers.add(peer)
        }
        deadPeers.forEach { partials.remove(it) }
    }

    fun forget(peer: Long) { partials.remove(peer) }

    val partialPeerCount: Int get() = partials.size
}

// ---- Dedup keep-rule (shared with every other bearer) -------------------------------------------------

/** Keep the leg whose "I am the greater id" role matches, identical to the LAN/BLE bearers. */
internal fun meshKeepGreaterLeg(amGreater: Boolean): Boolean = amGreater
