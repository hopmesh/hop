package net.waldrip.hop.demo

import java.util.ArrayDeque

/**
 * One Hop link carried over **GATT** instead of L2CAP — the reliable cross-platform fallback.
 *
 * Apple CoreBluetooth cannot open an L2CAP channel to an Android peripheral (it returns
 * CBErrorDomain "Unknown error"), so iOS↔Android can't use the fast L2CAP path. GATT writes +
 * indications work in every direction (and survive iOS background), so we frame the node's opaque
 * packets the SAME way HopLink does — a 4-byte big-endian length then that many bytes — but ship
 * them as GATT operations, chunked to the negotiated MTU.
 *
 * Reliability is at the BLE layer: the central writes with WRITE_TYPE_DEFAULT (write-with-response)
 * and the peripheral sends INDICATIONS — both are acknowledged, so chunks arrive in order without
 * loss. That requires strict **one-op-at-a-time** flow control: queue a frame, send a chunk, wait
 * for the completion callback ([onChunkSent]), then send the next. This class owns that state; the
 * bearer supplies the actual GATT op via [sendChunk] and feeds completions/receipts back in.
 */
class GattDataLink(
    val id: ULong,
    private val usablePayload: () -> Int,            // MTU - 3 (ATT opcode + handle), kept current
    private val sendChunk: (ByteArray) -> Boolean,   // perform the GATT write/indicate; false = couldn't start
    private val onBytes: (ULong, ByteArray) -> Unit, // a complete reassembled frame
    private val onClose: (ULong) -> Unit,
) {
    private val outFrames = ArrayDeque<ByteArray>()  // complete framed buffers awaiting send
    private var cursor: ByteArray? = null            // frame currently being chunked out
    private var offset = 0
    private var inFlight = false                      // a chunk is awaiting its completion callback
    private val inBuf = ArrayList<Byte>()            // inbound reassembly buffer
    @Volatile private var closed = false
    @Volatile private var lastRx = System.currentTimeMillis()
    @Volatile private var gotFrame = false           // received at least one real (non-keepalive) frame
    private val created = System.currentTimeMillis()

    /** Frame and queue an outbound packet (empty = keepalive); kicks the pump. All calls on main. */
    @Synchronized
    fun send(bytes: ByteArray) {
        if (closed) return
        val n = bytes.size
        val framed = ByteArray(4 + n)
        framed[0] = (n ushr 24).toByte(); framed[1] = (n ushr 16).toByte()
        framed[2] = (n ushr 8).toByte();  framed[3] = n.toByte()
        System.arraycopy(bytes, 0, framed, 4, n)
        outFrames.addLast(framed)
        pump()
    }

    /** The previous [sendChunk] completed — advance to the next chunk/frame. */
    @Synchronized
    fun onChunkSent() {
        inFlight = false
        pump()
    }

    /** A GATT write/indication arrived: reassemble and surface whole frames. */
    @Synchronized
    fun onChunkReceived(data: ByteArray) {
        if (closed) return
        lastRx = System.currentTimeMillis()
        inBuf.ensureCapacity(inBuf.size + data.size)
        for (b in data) inBuf.add(b)
        // Deframe: [4-byte len][payload], possibly several per buffer; len==0 is a keepalive.
        while (inBuf.size >= 4) {
            val len = ((inBuf[0].toInt() and 0xff) shl 24) or ((inBuf[1].toInt() and 0xff) shl 16) or
                ((inBuf[2].toInt() and 0xff) shl 8) or (inBuf[3].toInt() and 0xff)
            if (len < 0 || len > MAX_FRAME) { close(); return }
            val total = 4 + len
            if (inBuf.size < total) break
            if (len > 0) {
                val frame = ByteArray(len)
                for (i in 0 until len) frame[i] = inBuf[4 + i]
                gotFrame = true
                onBytes(id, frame)
            }
            // Drop the consumed bytes.
            repeat(total) { inBuf.removeAt(0) }
        }
    }

    /** Send the next chunk if the channel is idle and there's data. */
    private fun pump() {
        if (closed || inFlight) return
        if (cursor == null) {
            cursor = outFrames.pollFirst() ?: return
            offset = 0
        }
        val frame = cursor ?: return
        val room = usablePayload().coerceAtLeast(MIN_CHUNK)
        val end = minOf(offset + room, frame.size)
        val chunk = frame.copyOfRange(offset, end)
        inFlight = true
        if (!sendChunk(chunk)) {           // couldn't even start the op (peer gone / congested)
            inFlight = false
            close()
            return
        }
        offset = end
        if (offset >= frame.size) { cursor = null }  // frame fully queued; next pump pulls the next
    }

    /** Liveness: closed by the bearer's watchdog. Reaped fast if no frame ever arrives (half-open). */
    fun idleMs(): Long = System.currentTimeMillis() - lastRx
    fun isHalfOpen(): Boolean = !gotFrame && System.currentTimeMillis() - created > HANDSHAKE_TIMEOUT_MS

    @Synchronized
    fun close() {
        if (closed) return
        closed = true
        onClose(id)
    }

    companion object {
        const val GATT_LINK_BASE = 60_000UL              // link-id range for GATT-data links
        private const val MAX_FRAME = 4 * 1024 * 1024
        private const val MIN_CHUNK = 20                 // default ATT MTU 23 - 3
        private const val HANDSHAKE_TIMEOUT_MS = 4000L
    }
}
