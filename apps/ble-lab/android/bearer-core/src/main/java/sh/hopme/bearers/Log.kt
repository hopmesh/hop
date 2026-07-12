package sh.hopme.bearers

// Transport-neutral helpers shared by the core, every bearer lib, and the proof consumer. Nothing here
// is BLE/LAN-specific — just the grep-able log tag, the app-lifecycle flag every bearer reads, and the
// byte/hex utility so every transport + consumer emit the SAME `HOPLOG` lines and short-peer labels.
// The Android mirror of apple/HopBearers' Log.swift.

/// The shared logcat tag. Every bearer and consumer logs under it, so `adb logcat -s HOPLOG` captures
/// the whole transport layer end to end.
const val TAG = "HOPLOG"

/// R7: set from the app lifecycle; foreground-service default = false. Lives in the core so ANY bearer
/// reads it (to lengthen its liveness deadline in the background) without depending on the app or on
/// another transport. (apple/HopBearers: `bleAppInBackground`.)
@Volatile
var appInBackground = false

/// Lowercase hex of a byte array — the short-peer label primitive shared by transport + consumer logs.
fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }
