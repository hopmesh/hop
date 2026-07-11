package sh.hopme.demo

import com.google.zxing.BarcodeFormat
import com.google.zxing.qrcode.QRCodeWriter
import sh.hopme.driver.HopBearer

// cov/android-demo: the demo app's pure, non-UI-bound formatting + encoding helpers, lifted out of
// MainActivity.kt (which is otherwise wall-to-wall @Composable render bodies) so they can be unit-tested
// on the JVM. Behavior-preserving move: these were `private` top-level funcs in MainActivity.kt and are
// now `internal` so the Compose screens (same module/package) still call them and the test source set
// can exercise them. The Compose screens, the Activity/permission/camera/zxing-scan code, and the
// SendingIndicator/FaIcon composables stay in MainActivity.kt and are excluded from the coverage
// denominator (UI/device-bound), mirroring the driver's uniffi/** + KeystoreSecret exclusions.

/// Human display label for a peer's platform tag.
internal fun platformLabel(p: String): String = when (p) {
    "ios" -> "iOS"; "android" -> "Android"; else -> p
}

/// Font Awesome (Light) vector per direct transport, mirroring the iOS SF Symbols. "LAN" is a
/// shared-network Wi-Fi link (mDNS); "P2P" is peer-to-peer Wi-Fi (iOS Multipeer/AWDL); "Relay" is
/// the cloud backbone. Returns null for an unknown tag (no icon). bluetooth-b is a brand glyph.
internal fun transportIcon(tag: String): Int? = when (tag) {
    "BT" -> R.drawable.ic_fa_bluetooth_b
    "LAN" -> R.drawable.ic_fa_wifi
    "P2P" -> R.drawable.ic_fa_circle_nodes
    "Relay" -> R.drawable.ic_fa_cloud
    else -> null
}

/// Encode text (our "<base58>|<name>") to a QR bitmap via zxing core.
internal fun makeQrBitmap(text: String, size: Int = 600): android.graphics.Bitmap {
    val bits = QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, size, size)
    val bmp = android.graphics.Bitmap.createBitmap(size, size, android.graphics.Bitmap.Config.RGB_565)
    for (x in 0 until size) for (y in 0 until size)
        bmp.setPixel(x, y, if (bits[x, y]) android.graphics.Color.BLACK else android.graphics.Color.WHITE)
    return bmp
}

/// Decode + downscale an image to a modest JPEG so the mesh transfer stays reasonable: the carrier
/// path chunks it (§20), but smaller means fewer chunks and faster across wakes.
internal fun jpegDownscale(raw: ByteArray, maxDim: Int = 1280, quality: Int = 80): ByteArray {
    val src = android.graphics.BitmapFactory.decodeByteArray(raw, 0, raw.size) ?: return raw
    val longest = maxOf(src.width, src.height).toFloat()
    val scale = longest / maxDim
    val bmp = if (scale > 1f) {
        android.graphics.Bitmap.createScaledBitmap(
            src, (src.width / scale).toInt(), (src.height / scale).toInt(), true
        )
    } else src
    val out = java.io.ByteArrayOutputStream()
    bmp.compress(android.graphics.Bitmap.CompressFormat.JPEG, quality, out)
    return out.toByteArray()
}

/// One-line metadata under a chat bubble (mirrors the iOS app).
internal fun messageMeta(m: HopBearer.Message): String {
    if (m.incoming) {
        var s = HopBearer.hopsLabel(m.hops)
        m.latencyMs?.let { s += ", ${HopBearer.compactDuration(it)}" }
        if (m.trace.isNotEmpty()) s += "  ·  via ${m.trace.joinToString(" → ")}"
        return s
    }
    if (m.delivered) {
        // FORWARD (A->B) time the recipient reported (how long the message took to reach them),
        // not the A->B->A round trip (the ACK's return leg is uninteresting).
        val dur = HopBearer.compactDuration(m.deliveryMs ?: 0uL)
        return "Delivered, ${HopBearer.hopsLabel(m.deliveryHops)}, $dur"
    }
    if (m.failed) return "Not sent"
    // relayed == 0 is rendered by SendingIndicator (pulsing + live timer), not this string.
    return "Sent · ${m.relayed} peer${if (m.relayed == 1u) "" else "s"}"
}

/// Coerce a user-typed address bar value into a hops:// URL: keep an explicit hops:// as-is, else
/// strip an http(s):// prefix and re-scheme it to hops://.
internal fun normalizeHops(s: String): String {
    val t = s.trim()
    return if (t.startsWith("hops://")) t else "hops://" + t.removePrefix("https://").removePrefix("http://")
}

/// HTTP status reason phrase for the small set of codes the mesh browser surfaces.
internal fun statusText(code: Int): String = when (code) {
    200 -> "OK"; 404 -> "Not Found"; 502 -> "Bad Gateway"; 503 -> "Unavailable"; 504 -> "Timeout"
    else -> "Status"
}
