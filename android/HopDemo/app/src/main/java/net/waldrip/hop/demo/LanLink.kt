package net.waldrip.hop.demo

import java.io.DataInputStream
import java.net.Socket
import java.util.concurrent.LinkedBlockingQueue
import kotlin.concurrent.thread

/**
 * One LAN/Wi-Fi TCP link over a plain [Socket], with the SAME 4-byte big-endian length-prefix
 * framing as [HopLink] (the BLE L2CAP link). This is the cross-platform high-bandwidth path:
 * two devices on the same Wi-Fi (or a Wi-Fi Direct group) discover each other and talk over TCP —
 * iOS↔Android and Android↔Android (unlike MultipeerConnectivity/AWDL, which is Apple-only).
 *
 * Reliability mirrors [HopLink]: a keepalive sends an empty (0-length) frame every few seconds, and
 * a watchdog closes the link if nothing has been received for too long. Close is idempotent.
 */
class LanLink(
    val id: ULong,
    private val socket: Socket,
    private val onBytes: (ULong, ByteArray) -> Unit,
    private val onClose: (ULong) -> Unit,
) {
    private val outbox = LinkedBlockingQueue<ByteArray>()
    @Volatile private var running = true
    @Volatile private var lastRead = System.currentTimeMillis()

    init {
        runCatching { socket.tcpNoDelay = true }
        thread(name = "lanlink-read-$id") { readLoop() }
        thread(name = "lanlink-write-$id") { writeLoop() }
        thread(name = "lanlink-keepalive-$id") { keepaliveLoop() }
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
            val input = DataInputStream(socket.getInputStream())   // throws if socket already closed
            while (running) {
                val len = input.readInt() // big-endian by contract
                if (len < 0 || len > MAX_FRAME) throw IllegalStateException("bad frame len $len")
                lastRead = System.currentTimeMillis()
                if (len == 0) continue // keepalive — liveness only, nothing to surface
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
            val output = socket.getOutputStream()   // throws if socket already closed → caught, not fatal
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
        private val POISON = ByteArray(0) // close sentinel, distinguished by reference identity
    }
}
