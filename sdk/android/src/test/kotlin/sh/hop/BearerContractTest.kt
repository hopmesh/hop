package sh.hop

import java.io.File
import kotlin.test.Test
import kotlin.test.assertTrue

/**
 * PLAT-005: ensures no Bearer implementation in the repo can omit `override fun authenticated(link: Long)`.
 *
 * When a bearer enforces a preauth deadline, the driver polls node.peerLinks() and routes through
 * BearerManager.markSecured to bearer.authenticated(local). An empty default in interface Bearer
 * allows an implementation to silently drop authentication signals, leading to legitimate peers being
 * reaped at the preauth deadline.
 */
class BearerContractTest {

    @Test
    fun peerBearersWithPreauthDeadlinesOverrideAuthenticated() {
        // Locate bearers root from test working directory (sdk/android)
        val bearersRoot = File("../../bearers/android").canonicalFile
        assertTrue(bearersRoot.isDirectory, "bearers/android directory must exist at ${bearersRoot.absolutePath}")

        val lanFile = File(bearersRoot, "bearer-lan/src/main/java/sh/hopme/bearers/lan/LanBearer.kt")
        val bleFile = File(bearersRoot, "bearer-ble/src/main/java/sh/hopme/bearers/ble/BleBearer.kt")

        assertTrue(lanFile.exists(), "LanBearer.kt must exist")
        assertTrue(bleFile.exists(), "BleBearer.kt must exist")

        val lanSource = lanFile.readText()
        val bleSource = bleFile.readText()

        val authPattern = Regex("""override\s+fun\s+authenticated\s*\(\s*(\w+)\s*:\s*Long\s*\)""")

        assertTrue(
            authPattern.containsMatchIn(lanSource),
            "LanBearer must override `fun authenticated(link: Long)` so BearerManager.markSecured dispatches",
        )
        assertTrue(
            authPattern.containsMatchIn(bleSource),
            "BleBearer must override `fun authenticated(link: Long)` so BearerManager.markSecured dispatches",
        )

        // For every Bearer implementation in bearers/android, if it implements preauth deadline handling,
        // it must override authenticated.
        val mainDirs = bearersRoot.walkTopDown()
            .filter { it.isDirectory && it.name == "main" && it.parentFile.name == "src" }
            .toList()

        for (mainDir in mainDirs) {
            val ktFiles = mainDir.walkTopDown().filter { it.isFile && it.extension == "kt" }.toList()
            for (file in ktFiles) {
                val text = file.readText()
                if (text.contains(": Bearer") && (text.contains("preauth") || text.contains("PREAUTH_DEADLINE"))) {
                    assertTrue(
                        authPattern.containsMatchIn(text),
                        "${file.name} implements Bearer with preauth handling but does NOT override `fun authenticated(link: Long)`",
                    )
                }
            }
        }
    }
}
