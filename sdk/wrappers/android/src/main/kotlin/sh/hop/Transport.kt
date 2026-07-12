// Transport — small transport-neutral helpers every Android bearer module shares (so a bearer depends
// on nothing but this SDK), at parity with the Swift Transport.swift / the old ble-lab bearer-core.
// Nothing radio-specific: the grep-able log tag, the app-lifecycle flag, the one 16-byte nodeId + the
// "greater nodeId dials" tiebreaker, and the hex helper.

package sh.hop

import java.security.SecureRandom

/** The shared logcat tag — `adb logcat -s HOPLOG` captures the whole transport layer. */
const val TAG = "HOPLOG"

/** Set from the app lifecycle (foreground-service default = false). Any bearer reads it to lengthen
 *  its liveness deadline in the background, without depending on the app or another transport. */
@Volatile
var appInBackground = false

/** A fresh random 16-byte nodeId (CSPRNG). The host mints one and hands it to every bearer it
 *  registers, so all transports share one identity — distinct from the Hop node address. */
fun randomNodeId(): ByteArray = ByteArray(16).also { SecureRandom().nextBytes(it) }

/** Unsigned big-endian compare: a > b. The cross-transport tiebreaker — "greater nodeId dials" — so
 *  two peers that both discover each other don't double-connect. */
fun nodeIdGreater(a: ByteArray, b: ByteArray): Boolean {
    for (i in 0 until minOf(a.size, b.size)) {
        val x = a[i].toInt() and 0xff
        val y = b[i].toInt() and 0xff
        if (x != y) return x > y
    }
    return a.size > b.size
}

/** Lowercase hex of a byte array — the short-peer label primitive shared across transport logs. */
fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }
