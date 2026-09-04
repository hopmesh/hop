package sh.hopme.bearers.relay

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.shadows.ShadowLog
import sh.hop.TAG

@RunWith(RobolectricTestRunner::class)
class RelaySanitizerTest {

    private var bearer: RelayBearer? = null

    @After fun tearDown() {
        bearer?.stop()
        ShadowLog.clear()
    }

    @Test fun candidateUrlWithCredentialsOrQueryIsSanitizedInLogs() {
        ShadowLog.clear()
        val rawUrl = "wss://relay.example.com/hop?token=supersecret12345&user=alice#fragment"
        val b = RelayBearer(rawUrl)
        bearer = b
        b.start()

        val deadline = System.currentTimeMillis() + 3000
        while (System.currentTimeMillis() < deadline &&
            ShadowLog.getLogsForTag(TAG).none { it.msg.contains("relay dial") }
        ) {
            Thread.sleep(20)
        }

        val logs = ShadowLog.getLogsForTag(TAG)
        val dialLogs = logs.filter { it.msg.contains("relay dial") }
        assertTrue("must have logged relay dial attempt", dialLogs.isNotEmpty())

        for (log in dialLogs) {
            assertFalse(
                "query credentials must never appear in log: ${log.msg}",
                log.msg.contains("supersecret12345"),
            )
            assertFalse(
                "fragment must never appear in log: ${log.msg}",
                log.msg.contains("fragment"),
            )
            assertTrue(
                "sanitized url must be logged: ${log.msg}",
                log.msg.contains("relay dial wss://relay.example.com/hop"),
            )
        }
    }

    @Test fun directSanitizeFunctionStripsCredentialsAndFragments() {
        assertEquals(
            "wss://relay.example.com/hop",
            RelayBearer.sanitizeRelayUrl("wss://relay.example.com/hop?token=secret"),
        )
        assertEquals(
            "wss://relay.example.com/hop",
            RelayBearer.sanitizeRelayUrl("wss://relay.example.com/hop#fragment"),
        )
        assertEquals(
            "wss://relay.example.com/hop",
            RelayBearer.sanitizeRelayUrl("  wss://relay.example.com/hop?token=secret&key=123#frag  "),
        )
        assertEquals(
            "wss://relay.example.com/hop",
            RelayBearer.sanitizeRelayUrl("wss://relay.example.com/hop"),
        )
    }
}
