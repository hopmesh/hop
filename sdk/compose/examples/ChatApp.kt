// A minimal end-to-end example: a home list of conversations that opens into a chat screen. This is
// shared Compose Multiplatform code; the same source runs on Android, Desktop, and iOS. The only thing
// each platform supplies is the HopEngine (JnaHopEngine on the JVM, an Apple-SDK adapter on iOS).
//
// This file is illustrative and not part of the compiled library.

package sh.hop.compose.examples

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import sh.hop.compose.HopAddress
import sh.hop.compose.HopConversationList
import sh.hop.compose.HopConversationScreen
import sh.hop.compose.HopEngine
import sh.hop.compose.rememberHopClient

@Composable
fun ChatApp(engine: HopEngine) {
    // One client for the whole app; it starts the node loop and stops it when this leaves composition.
    val client = rememberHopClient(engine)
    var open by remember { mutableStateOf<HopAddress?>(null) }

    MaterialTheme {
        Scaffold { padding ->
            val current = open
            if (current == null) {
                HopConversationList(
                    client = client,
                    onOpen = { open = it },
                    modifier = Modifier.padding(padding),
                )
            } else {
                HopConversationScreen(
                    client = client,
                    peer = current,
                    modifier = Modifier.padding(padding),
                )
            }
        }
    }
}
