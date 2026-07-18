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

/** Stream a picked attachment with a hard cap, returning null before an oversized body is buffered. */
internal fun readCapped(input: java.io.InputStream, maximum: Int = 32 * 1024 * 1024): ByteArray? {
    val output = java.io.ByteArrayOutputStream(minOf(maximum, 8 * 1024))
    val buffer = ByteArray(8 * 1024)
    var total = 0
    while (true) {
        val count = input.read(buffer)
        if (count < 0) break
        if (count > maximum - total) return null
        output.write(buffer, 0, count)
        total += count
    }
    return output.toByteArray()
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
    val lower = t.lowercase()
    return when {
        lower.startsWith("hops://") -> "hops://" + t.substring(7)
        lower.startsWith("https://") -> "hops://" + t.substring(8)
        lower.startsWith("http://") -> "hops://" + t.substring(7)
        else -> "hops://$t"
    }
}

/** True only for a canonical hierarchical hops URL, plus the explicit local `about:blank` bootstrap. */
internal fun browserAllowsURL(raw: String, relativeTo: String? = null): Boolean {
    val input = raw.trim()
    if (input.equals("about:blank", ignoreCase = true)) return true
    if (input.isEmpty() || input.contains('\\')) return false
    val parsed = runCatching { java.net.URI(input) }.getOrNull() ?: return false
    val uri = if (parsed.isAbsolute) parsed else {
        val base = relativeTo?.let { runCatching { java.net.URI(it) }.getOrNull() } ?: return false
        runCatching { base.resolve(parsed) }.getOrNull() ?: return false
    }
    if (!uri.scheme.equals("hops", ignoreCase = true) || uri.isOpaque || uri.userInfo != null ||
        uri.port != -1 || uri.fragment != null) return false
    val host = uri.host?.lowercase() ?: return false
    if (host.length !in 1..253 || host.endsWith('.')) return false
    return host.split('.').all { label ->
        label.length in 1..63 && label.first() != '-' && label.last() != '-' &&
            label.all { it.isLetterOrDigit() || it == '-' }
    }
}

/** Defense in depth for subresources that a WebView may resolve without a client callback. */
internal const val HOPS_CONTENT_SECURITY_POLICY =
    "default-src 'none'; img-src hops:; style-src hops:; font-src hops:; frame-src hops:; " +
        "media-src hops:; connect-src hops:; script-src 'none'; object-src 'none'; " +
        "base-uri 'none'; form-action 'none'"

/// HTTP status reason phrase for the small set of codes the mesh browser surfaces.
internal fun statusText(code: Int): String = when (code) {
    200 -> "OK"; 404 -> "Not Found"; 502 -> "Bad Gateway"; 503 -> "Unavailable"; 504 -> "Timeout"
    else -> "Status"
}
