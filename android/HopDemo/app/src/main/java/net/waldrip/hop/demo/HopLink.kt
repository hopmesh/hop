package net.waldrip.hop.demo

import android.bluetooth.BluetoothSocket
import java.io.DataInputStream
import java.util.concurrent.LinkedBlockingQueue
import kotlin.concurrent.thread

/**
 * One L2CAP connection-oriented channel, framed as length-prefixed packets so the
 * node's opaque byte packets survive the stream boundary: a 4-byte big-endian
 * length, then that many bytes. A reader thread surfaces whole frames; a writer
 * thread drains a queue. Mirrors the iOS [HopLink].
 */
class HopLink(
    val id: ULong,
    private val socket: BluetoothSocket,
    private val onBytes: (ULong, ByteArray) -> Unit,
    private val onClose: (ULong) -> Unit,
) {
    private val outbox = LinkedBlockingQueue<ByteArray>()
    @Volatile private var running = true

    init {
        thread(name = "hoplink-read-$id") { readLoop() }
        thread(name = "hoplink-write-$id") { writeLoop() }
    }

    fun send(bytes: ByteArray) {
        if (running) outbox.put(bytes)
    }

    fun close() {
        running = false
        outbox.put(ByteArray(0)) // unblock the writer
        runCatching { socket.close() }
    }

    private fun readLoop() {
        val input = DataInputStream(socket.inputStream)
        try {
            while (running) {
                val len = input.readInt() // big-endian by contract
                if (len < 0 || len > MAX_FRAME) throw IllegalStateException("bad frame len $len")
                val buf = ByteArray(len)
                input.readFully(buf)
                onBytes(id, buf)
            }
        } catch (_: Throwable) {
            // stream closed or error
        } finally {
            if (running) { running = false; onClose(id) }
        }
    }

    private fun writeLoop() {
        val output = socket.outputStream
        try {
            while (running) {
                val payload = outbox.take()
                if (!running) break
                if (payload.isEmpty()) continue
                val header = ByteArray(4)
                header[0] = (payload.size ushr 24).toByte()
                header[1] = (payload.size ushr 16).toByte()
                header[2] = (payload.size ushr 8).toByte()
                header[3] = payload.size.toByte()
                output.write(header)
                output.write(payload)
                output.flush()
            }
        } catch (_: Throwable) {
            if (running) { running = false; onClose(id) }
        }
    }

    companion object {
        private const val MAX_FRAME = 4 * 1024 * 1024
    }
}
