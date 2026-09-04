package sh.hopme.bearers.meshtastic

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.ParcelUuid
import android.os.Handler
import android.os.Looper
import android.util.Log
import sh.hop.Bearer
import sh.hop.HopRole
import sh.hop.LinkId
import sh.hop.LinkSink
import sh.hop.TAG
import sh.hop.nodeIdGreater
import java.util.ArrayDeque
import sh.hop.toHex
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

// MeshtasticBearer - the Hop transport that RELAYS through a connected Meshtastic radio, the Android mirror
// of bearers/apple/HopBearerMeshtastic. A phone pairs with a nearby Meshtastic device over BLE; that device
// is a gateway into a LoRa mesh where every radio relays packets hop by hop. This bearer turns that mesh
// into a Hop transport: each remote Meshtastic node also running Hop becomes a peer, Hop link frames are
// fragmented into LoRa-sized Meshtastic packets on a private app port, and the mesh carries them. The
// consumer sees identical linkUp/linkBytes/linkDown semantics, keyed on the peer's 16-byte nodeId.
//
// TESTABILITY. All Meshtastic PROTOCOL logic (protobuf, fragmentation, the Hop link-frame grammar, dedup)
// lives in MeshtasticWire.kt and is unit-tested with no radio. This file owns the LINK STATE MACHINE and
// drives a `MeshtasticRadio` seam that moves raw ToRadio/FromRadio protobuf frames. In production the seam
// is AndroidMeshtasticRadio (the BluetoothGatt client, DEVICE-BOUND and excluded from the coverage
// denominator like :bearer-lan's NSD glue). In tests it is a fake radio, so the whole state machine runs on
// a plain JVM with an injected clock.
//
// THREADING. One single-thread executor (`work`) owns every link/reassembly/timer mutation, so the state
// machine is single-threaded end to end and needs no locks (mirrors the Apple bearer's serial queue). The
// radio delivers inbound frames onto this executor.

/** The seam between the state machine and the physical Meshtastic device. Moves opaque protobuf frames. */
internal interface MeshtasticRadio {
    var onConnect: (() -> Unit)?
    var onDisconnect: (() -> Unit)?
    var onFromRadio: ((ByteArray) -> Unit)?
    fun start()
    fun stop()
    fun sendToRadio(bytes: ByteArray)
}

/** One logical link to a remote Meshtastic node (at most one per node num). */
internal class MeshLink(
    val linkId: Long,
    val nodeNum: Long,
    var peerId: ByteArray,
    /** True iff MY nodeId is the greater one (the Noise initiator). */
    val isGreater: Boolean,
    nowMs: Long,
) {
    var up = false
    var surfaced = false
    var lastRxMs = nowMs
    var lastPingMs = nowMs
    var txSeq = 0L
    val role: HopRole get() = if (isGreater) HopRole.DIALER else HopRole.ACCEPTOR
    val peerShort: String get() = peerId.toHex().take(8)
}

class MeshtasticBearer internal constructor(
    private val myId: ByteArray,
    private val radio: MeshtasticRadio,
) : Bearer {
    /** Production constructor: talk to a real Meshtastic radio over BLE. */
    constructor(context: Context, myId: ByteArray) : this(myId, AndroidMeshtasticRadio(context))

    override var sink: LinkSink? = null
    /// Short transport tag for the consumer's UI (Bearer contract). Meshtastic/LoRa links surface as "LoRa".
    override val transportName = "LoRa"

    private var work: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor()
    private val linksByNode = HashMap<Long, MeshLink>()
    private val linksByLinkId = HashMap<Long, MeshLink>()
    private val reassembler = MeshReassembler()
    private var nextLinkId = 1L
    private var nextMsgId = 1
    private var nextPktId = 1L
    private var myNodeNum: Long? = null
    private var stopped = false
    private var lastBeaconMs = 0L
    private var configNonce = 1L
    private var radioUp = false
    private var hopChannel: Int? = null
    private var sessionPasskey = ByteArray(0)
    private var channelProbe = 1
    private val sprays = ArrayList<Spray>()
    private val seenMsgIds = HashMap<Long, ArrayDeque<Int>>()

    private class Spray(
        val dest: Long,
        val msgId: Int,
        val frame: ByteArray,
        var nextDueMs: Long,
        var intervalMs: Long,
    )

    override fun start() {
        if (work.isShutdown) work = Executors.newSingleThreadScheduledExecutor()
        submit {
            stopped = false
            radio.onConnect = { submit { onRadioConnected() } }
            radio.onDisconnect = { submit { onRadioDisconnected() } }
            radio.onFromRadio = { bytes -> submit { onFromRadio(bytes) } }
            radio.start()
        }
        try {
            work.scheduleAtFixedRate(
                { runCatching { runMaintenance(System.currentTimeMillis()) } },
                MESH_SPRAY_TICK_MS, MESH_SPRAY_TICK_MS, TimeUnit.MILLISECONDS,
            )
        } catch (_: RejectedExecutionException) {
            stopped = true
        }
        Log.i(TAG, "mesh node-start myId=${myId.toHex()} port=$MESH_HOP_PORTNUM")
    }

    override fun stop() {
        submit {
            stopped = true
            for (link in ArrayList(linksByNode.values)) teardown(link, "stop")
            radio.stop()
        }
        work.shutdown()
    }

    override fun send(bytes: ByteArray, link: LinkId) {
        submit {
            val l = linksByLinkId[link] ?: return@submit
            shipFrame(MeshFrame.data(bytes), l.nodeNum)
        }
    }

    // ---- Radio callbacks (all on the work thread) -----------------------------------------------------

    private fun onRadioConnected() {
        if (stopped) return
        radioUp = true
        hopChannel = null
        channelProbe = 1
        sessionPasskey = ByteArray(0)
        Log.i(TAG, "mesh radio-connected, requesting config")
        configNonce += 1
        radio.sendToRadio(MeshtasticProto.encodeWantConfig(configNonce))
        requestHopChannel()
    }

    private fun onRadioDisconnected() {
        radioUp = false
        hopChannel = null
        channelProbe = 1
        sessionPasskey = ByteArray(0)
        for (link in ArrayList(linksByNode.values)) teardown(link, "radio down")
        myNodeNum = null
    }

    private fun onFromRadio(bytes: ByteArray) {
        if (stopped) return
        when (val inbound = MeshtasticProto.decodeFromRadio(bytes)) {
            is MeshInbound.MyNodeNum -> {
                if (myNodeNum != inbound.num) Log.i(TAG, "mesh my-node-num=${inbound.num}")
                myNodeNum = inbound.num
                requestHopChannel()
            }
            is MeshInbound.SeenNode -> Log.i(TAG, "mesh node-info num=${inbound.num}")
            is MeshInbound.Admin -> onAdmin(inbound.payload)
            is MeshInbound.Routing -> Log.i(TAG, "mesh routing id=${inbound.requestId} error=${inbound.error}")
            is MeshInbound.HopData -> {
                if (inbound.from == 0L || inbound.from == myNodeNum) {
                    Log.i(TAG, "mesh hop echo from=${inbound.from} me=$myNodeNum")
                    return
                }
                val done = reassembler.accept(inbound.from, inbound.payload, System.currentTimeMillis())
                    ?: return
                handleFrame(inbound.from, done.msgId, done.body)
            }
            null -> {
                val peek = MeshtasticProto.peekPacketPort(bytes)
                val fields = ArrayList<Int>()
                val pr = ProtoReader(bytes)
                while (true) {
                    val tag = pr.readTag() ?: break
                    fields.add(tag.first)
                    if (!pr.skip(tag.second)) break
                }
                Log.i(TAG, "mesh fromRadio drop len=${bytes.size} b0=${bytes.first().toInt() and 0xff} from=${peek?.first} port=${peek?.second} fields=$fields")
            }
        }
    }

    private fun requestHopChannel() {
        if (!radioUp || myNodeNum == null || hopChannel != null) return
        sendAdmin(MeshtasticProto.encodeGetChannelRequest(channelProbe))
    }

    private fun sendAdmin(admin: ByteArray) {
        val me = myNodeNum ?: return
        val id = nextPktId; nextPktId = (nextPktId + 1) and 0xffffffffL
        radio.sendToRadio(MeshtasticProto.encodeAdminToRadio(me, id, admin))
    }

    private fun onAdmin(payload: ByteArray) {
        val inbound = MeshtasticProto.decodeAdminMessage(payload) ?: return
        if (inbound.passkey.isNotEmpty()) sessionPasskey = inbound.passkey
        val ch = inbound.channel ?: return
        if (hopChannel != null) return
        when {
            ch.isHop -> armHopChannel(ch.index)
            ch.isFree -> {
                sendAdmin(MeshtasticProto.encodeSetHopChannel(sessionPasskey, ch.index))
                armHopChannel(ch.index)
            }
            else -> {
                val next = ch.index + 1
                if (next < MESH_MAX_CHANNELS) {
                    channelProbe = next
                    sendAdmin(MeshtasticProto.encodeGetChannelRequest(next))
                } else {
                    Log.w(TAG, "mesh no secondary slot for Hop")
                }
            }
        }
    }

    private fun armHopChannel(index: Int) {
        hopChannel = index
        Log.i(TAG, "mesh hop-channel=$index")
        broadcastHello()
    }

    private fun handleFrame(node: Long, msgId: Int, body: ByteArray) {
        if (body.isEmpty()) return
        linksByNode[node]?.let { it.lastRxMs = System.currentTimeMillis() }
        when (body[0].toInt() and 0xff) {
            M_ACK -> {
                val id = MeshFrame.ackMsgId(body) ?: return
                sprays.removeAll { it.dest == node && it.msgId == id }
            }
            M_HELLO -> {
                sendAck(node, msgId)
                if (alreadySeen(node, msgId)) return
                MeshFrame.helloPeerId(body)?.let { onHello(node, it) }
            }
            M_PING -> {
                val echo = body.copyOfRange(1, minOf(17, body.size))
                shipFrame(MeshFrame.pong(echo), node)
            }
            M_PONG -> { /* liveness only */ }
            M_DATA -> {
                sendAck(node, msgId)
                if (alreadySeen(node, msgId)) return
                val l = linksByNode[node] ?: return
                if (l.up) sink?.linkBytes(l.linkId, body.copyOfRange(1, body.size))
            }
            else -> { /* unknown */ }
        }
    }

    private fun alreadySeen(peer: Long, msgId: Int): Boolean {
        val q = seenMsgIds.getOrPut(peer) { ArrayDeque() }
        if (q.contains(msgId)) return true
        q.addLast(msgId)
        while (q.size > 32) q.removeFirst()
        return false
    }

    private fun sendAck(node: Long, msgId: Int) {
        emitFrame(MeshFrame.ack(msgId), node, mintFragMsgId(), wantAck = false)
    }

    private fun onHello(node: Long, peerId: ByteArray) {
        if (peerId.contentEquals(myId)) return
        linksByNode[node]?.let { it.peerId = peerId; it.lastRxMs = System.currentTimeMillis(); return }
        val isGreater = meshKeepGreaterLeg(nodeIdGreater(myId, peerId))
        val link = MeshLink(mint(), node, peerId, isGreater, System.currentTimeMillis())
        link.up = true
        link.surfaced = true
        linksByNode[node] = link
        linksByLinkId[link.linkId] = link
        Log.i(TAG, "mesh hello-recv peer=${link.peerShort} node=$node greater=$isGreater")
        shipFrame(MeshFrame.hello(myId, isGreater), node)
        sink?.linkUp(link.linkId, link.role, peerId)
    }

    private fun mintFragMsgId(): Int {
        val id = nextMsgId
        nextMsgId = (nextMsgId + 1) and 0xffff
        return id
    }

    private fun shipFrame(frame: ByteArray, dest: Long) {
        val kind = if (frame.isEmpty()) 0 else frame[0].toInt() and 0xff
        val reliable = dest != MESH_BROADCAST_ADDR && (kind == M_DATA || kind == M_HELLO)
        val msgId = mintFragMsgId()
        emitFrame(frame, dest, msgId, wantAck = reliable)
        if (reliable) enqueueSpray(dest, msgId, frame, System.currentTimeMillis())
    }

    private fun emitFrame(frame: ByteArray, dest: Long, msgId: Int, wantAck: Boolean) {
        val ch = hopChannel ?: return
        val frags = meshFragment(frame, msgId) ?: run {
            Log.w(TAG, "mesh frame too large to fragment (${frame.size} bytes)"); return
        }
        for (frag in frags) {
            val id = nextPktId; nextPktId = (nextPktId + 1) and 0xffffffffL
            radio.sendToRadio(
                MeshtasticProto.encodeToRadioPacket(0L, dest, id, 3, frag, channel = ch, wantAck = wantAck),
            )
        }
    }

    private fun enqueueSpray(dest: Long, msgId: Int, frame: ByteArray, now: Long) {
        if (sprays.count { it.dest == dest } >= MESH_SPRAY_MAX_OUTSTANDING) {
            sprays.indexOfFirst { it.dest == dest }.takeIf { it >= 0 }?.let { sprays.removeAt(it) }
        }
        sprays.add(Spray(dest, msgId, frame, now + MESH_SPRAY_INITIAL_MS, MESH_SPRAY_INITIAL_MS))
    }

    private fun broadcastHello() {
        if (hopChannel == null) return
        shipFrame(MeshFrame.hello(myId, false), MESH_BROADCAST_ADDR)
        lastBeaconMs = System.currentTimeMillis()
    }

    private fun runMaintenance(now: Long) {
        if (stopped) return
        reassembler.evictStale(now)
        if (now - lastBeaconMs >= MESH_PING_MS) broadcastHello()
        for (s in ArrayList(sprays)) {
            if (now < s.nextDueMs) continue
            emitFrame(s.frame, s.dest, s.msgId, wantAck = true)
            s.intervalMs = minOf(s.intervalMs * MESH_SPRAY_MULTIPLIER, MESH_SPRAY_CAP_MS)
            s.nextDueMs = now + s.intervalMs
        }
        for (link in ArrayList(linksByNode.values)) {
            if (now - link.lastRxMs > MESH_DEAD_MS) { teardown(link, "liveness DEAD"); continue }
            if (now - link.lastPingMs >= MESH_PING_MS) {
                link.lastPingMs = now
                link.txSeq += 1
                shipFrame(MeshFrame.ping(link.txSeq, now), link.nodeNum)
            }
        }
    }

    private fun teardown(link: MeshLink, why: String) {
        linksByNode.remove(link.nodeNum)
        linksByLinkId.remove(link.linkId)
        reassembler.forget(link.nodeNum)
        sprays.removeAll { it.dest == link.nodeNum }
        seenMsgIds.remove(link.nodeNum)
        Log.i(TAG, "mesh link-down ($why) peer=${link.peerShort} node=${link.nodeNum}")
        if (link.surfaced) sink?.linkDown(link.linkId)
    }

    private fun mint(): Long { val id = nextLinkId; nextLinkId += 1; return id }

    private fun submit(block: () -> Unit) {
        try { work.execute { runCatching { block() } } } catch (_: RejectedExecutionException) {}
    }

    // ---- Test seams (bearer-meshtastic unit tests) ----------------------------------------------------
    // These run the REAL production paths on the work thread with a fake radio + injected clock, mirroring
    // the Apple DEBUG seams. They add NO behavior.

    /** Block until the work queue drains, so a test observes the effect of prior events. */
    internal fun awaitIdle() {
        val done = java.util.concurrent.CountDownLatch(1)
        work.execute { done.countDown() }
        done.await(2, TimeUnit.SECONDS)
    }

    internal fun runMaintenanceForTest(nowMs: Long) { submit { runMaintenance(nowMs) }; awaitIdle() }
    internal fun linkCountForTest(): Int { awaitIdle(); return linksByNode.size }
    internal fun myNodeNumForTest(): Long? { awaitIdle(); return myNodeNum }
}
