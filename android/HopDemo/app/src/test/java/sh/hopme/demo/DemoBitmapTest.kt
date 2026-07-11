package sh.hopme.demo

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.GraphicsMode
import java.io.ByteArrayOutputStream

/**
 * cov/android-demo: the QR + JPEG bitmap helpers. These touch real Android image codecs, so they run in
 * Robolectric's NATIVE graphics mode (a real Skia-backed Bitmap/BitmapFactory on the host) rather than
 * the legacy fake shadows - a legacy ShadowBitmapFactory fakes dimensions and never decodes, so it could
 * not exercise the downscale-vs-keep decision or the QR pixel loop for real.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class DemoBitmapTest {

    @Test fun makeQrBitmap_producesSquareWithDarkAndLightModules() {
        val bmp = makeQrBitmap("hop:someBase58Address|Alice", size = 120)
        assertEquals(120, bmp.width)
        assertEquals(120, bmp.height)
        val colors = HashSet<Int>()
        for (x in 0 until bmp.width) for (y in 0 until bmp.height) colors.add(bmp.getPixel(x, y))
        // A QR always has a light quiet zone AND dark finder/data modules, so both must be present.
        assertTrue("QR must contain both dark and light modules, got $colors", colors.size >= 2)
    }

    @Test fun makeQrBitmap_defaultSizeIs600() {
        // Exercises the default-argument path (size = 600) as well as the full encode + setPixel loop.
        val bmp = makeQrBitmap("hop:someBase58Address|Bob")
        assertEquals(600, bmp.width)
        assertEquals(600, bmp.height)
    }

    @Test fun jpegDownscale_keepsSmallImageUntouched() {
        val input = jpegBytes(100, 80)
        val out = jpegDownscale(input, maxDim = 1280)
        val decoded = BitmapFactory.decodeByteArray(out, 0, out.size)
        assertNotNull("downscaled output must decode", decoded)
        assertEquals(100, decoded!!.width)
        assertEquals(80, decoded.height)
    }

    @Test fun jpegDownscale_shrinksLargeImageToMaxLongestDimension() {
        val input = jpegBytes(2000, 1000)
        val out = jpegDownscale(input, maxDim = 1280)
        val decoded = BitmapFactory.decodeByteArray(out, 0, out.size)
        assertNotNull(decoded)
        // longest = 2000, scale = 2000/1280, so 2000 -> 1280 and 1000 -> 640.
        assertEquals(1280, decoded!!.width)
        assertEquals(640, decoded.height)
    }

    @Test fun jpegDownscale_returnsRawWhenUndecodable() {
        val garbage = byteArrayOf(1, 2, 3, 4, 5)
        assertSame("undecodable input is returned unchanged", garbage, jpegDownscale(garbage))
    }

    private fun jpegBytes(w: Int, h: Int): ByteArray {
        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val out = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.JPEG, 90, out)
        return out.toByteArray()
    }
}
