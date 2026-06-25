package net.waldrip.hop.demo

import android.bluetooth.BluetoothSocket
import java.io.DataInputStream
import java.util.concurrent.LinkedBlockingQueue
import kotlin.concurrent.thread

/**
 * One L2CAP connection-oriented channel, framed as length-prefixed packets so the node's opaque
 * byte packets survive the stream boundary: a 4-byte big-endian length, then that many bytes.
 *
 * Reliability — mirrors the iOS [HopLink]: a **keepalive** sends an empty (0-length) frame every
 * few seconds so the peer sees steady traffic, and a **watchdog** closes the link if nothing has
 * been received for too long. iOS closes a link that goes silent for ~15s, so without our own
 * keepalive an idle Android↔iOS link gets torn down by iOS every few seconds (status 19). Close
 * is idempotent.
 */
class HopLink(
    val id: ULong,
    private val socket: BluetoothSocket,
    private val onBytes: (ULong, ByteArray) -> Unit,
    private val onClose: (ULong) -> Unit,
) {
    private val outbox = LinkedBlockingQueue<ByteArray>()
    @Volatile private var running = true
    @Volatile private var lastRead = System.currentTimeMillis()
    private val created = System.currentTimeMillis()
    @Volatile private var gotFrame = false   // received at least one real (non-keepalive) frame

    init {
        thread(name = "hoplink-read-$id") { readLoop() }
        thread(name = "hoplink-write-$id") { writeLoop() }
        thread(name = "hoplink-keepalive-$id") { keepaliveLoop() }
    }

    fun send(bytes: ByteArray) {
        if (running && bytes.isNotEmpty()) outbox.put(bytes)
    }

    fun close() {
        if (!running) return
        running = false
        outbox.put(POISON)            // unblock the writer
        runCatching { socket.close() }
        onClose(id)
    }

    private fun readLoop() {
        try {
            val input = DataInputStream(socket.inputStream)   // throws if socket already closed
            while (running) {
                val len = input.readInt() // big-endian by contract
                if (len < 0 || len > MAX_FRAME) throw IllegalStateException("bad frame len $len")
                lastRead = System.currentTimeMillis()
                if (len == 0) continue // keepalive — liveness only, nothing to surface
                gotFrame = true
                val buf = ByteArray(len)
                input.readFully(buf)
                onBytes(id, buf)
            }
        } catch (_: Throwable) {
            // stream closed or error
        } finally {
            close()
        }
    }

    private fun writeLoop() {
        try {
            val output = socket.outputStream   // throws if socket already closed → caught, not fatal
            while (running) {
                val payload = outbox.take()
                if (payload === POISON || !running) break
                val n = payload.size // 0 for a keepalive frame
                output.write(byteArrayOf(
                    (n ushr 24).toByte(), (n ushr 16).toByte(), (n ushr 8).toByte(), n.toByte(),
                ))
                if (n > 0) output.write(payload)
                output.flush()
            }
        } catch (_: Throwable) {
            // stream closed or error
        } finally {
            close()
        }
    }

    private fun keepaliveLoop() {
        try {
            while (running) {
                Thread.sleep(KEEPALIVE_MS)
                if (!running) break
                // Half-open reaper: an inbound L2CAP channel that never delivered a single frame is a
                // dead half-open — iOS's openL2CAPChannel failed ("Unknown error") and abandoned its
                // end, but Android's accept() succeeded, so it sits here forever waiting for an m1 that
                // will never come. Reap it fast (not the 15s liveness timeout): these orphans otherwise
                // pile up against BT's concurrent-L2CAP-channel cap and trigger MORE open failures.
                if (!gotFrame && System.currentTimeMillis() - created > HANDSHAKE_TIMEOUT_MS) {
                    android.util.Log.i("HOPLOG", "ble link reaped (no handshake) id=$id")
                    close(); break
                }
                if (System.currentTimeMillis() - lastRead > LIVENESS_MS) { close(); break } // peer silent
                outbox.put(ByteArray(0)) // 0-length keepalive frame (distinct instance from POISON)
            }
        } catch (_: Throwable) {
        }
    }

    companion object {
        private const val MAX_FRAME = 4 * 1024 * 1024
        private const val KEEPALIVE_MS = 4000L
        private const val LIVENESS_MS = 15000L
        private const val HANDSHAKE_TIMEOUT_MS = 3500L  // reap a half-open that never sent a frame
        private val POISON = ByteArray(0) // close sentinel, distinguished by reference identity
    }
}
