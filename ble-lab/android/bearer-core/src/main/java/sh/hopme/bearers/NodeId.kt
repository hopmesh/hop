package sh.hopme.bearers

import java.security.SecureRandom

// A node's identity is ONE 16-byte id shared across every transport — a peer reached by BLE and by LAN
// is the SAME node. So id generation lives in the core, not in any single bearer: the host mints one id
// and hands it to every bearer it registers. The Android mirror of apple/HopBearers' NodeId.swift.

/// A fresh random 16-byte nodeId (CSPRNG). Stable for the process lifetime (SPEC R11). The host creates
/// it once and passes it to BleBearer, LanBearer, … so all transports share one identity.
fun randomNodeId(): ByteArray = ByteArray(16).also { SecureRandom().nextBytes(it) }

/// Unsigned big-endian compare: a > b (byte 0 most significant). The cross-transport tiebreaker
/// primitive — "greater nodeId dials" — so two peers that both discover each other don't double-connect.
fun nodeIdGreater(a: ByteArray, b: ByteArray): Boolean {
    for (i in 0 until minOf(a.size, b.size)) {
        val x = a[i].toInt() and 0xff
        val y = b[i].toInt() and 0xff
        if (x != y) return x > y
    }
    return a.size > b.size
}
