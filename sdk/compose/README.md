<p align="center">
  <img alt="Hop" src="https://hopme.sh/hop-mark.svg" width="200">
</p>

<h1 align="center">Hop for Compose Multiplatform</h1>

<p align="center">
  <b>One Kotlin codebase. A mesh messenger on Android, Desktop, and iOS.</b><br>
  The Compose UI SDK for the <a href="https://hopme.sh">Hop</a> mesh: a reactive client and drop-in composables over the <code>libhop</code> C ABI.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/license-Apache--2.0-3ddc84" alt="license">
  <img src="https://img.shields.io/badge/kotlin-2.4-7f52ff" alt="kotlin 2.4">
  <img src="https://img.shields.io/badge/compose-multiplatform-4285f4" alt="compose multiplatform">
</p>

---

Hop is a **delay-tolerant mesh**: end-to-end encrypted datagrams that hop device to device, over BLE,
Wi-Fi, and the internet, until they reach the person you meant. Held, never dropped.

`sdk/android` gives you a raw `HopNode`. **This** gives you the layer above it: a reactive `HopClient` that
runs the node's tick loop for you and publishes an immutable `HopClientState` as a `StateFlow`, plus
Compose Multiplatform composables (`HopConversationScreen`, `HopMessageList`, `HopMessageComposer`,
`HopConversationList`, `HopAddressChip`) that render it. Write your messenger UI once; run it on Android,
Desktop, and iOS.

## The one idea: the engine seam

The SDK depends on a single interface, `HopEngine`, never on any one native binding. On the JVM that
engine is the JNA `HopNode` (bundled adapter, `JnaHopEngine`); on iOS you supply an adapter over the Apple
xcframework. Everything else, the reactive client, the state reducer, and every composable, is pure
`commonMain`. That is why the whole SDK is unit-tested with no native library present, against an in-memory
fake engine.

```
Compose composables  ->  HopClient (StateFlow + inbox Flow)  ->  HopEngine  ->  libhop
      you write               the SDK runs the loop            the seam       the node
```

## Quick start (shared code)

```kotlin
import androidx.compose.runtime.Composable
import sh.hop.compose.HopEngine
import sh.hop.compose.HopConversationScreen
import sh.hop.compose.rememberHopClient

@Composable
fun Chat(engine: HopEngine, peerBase58: String) {
    val client = rememberHopClient(engine) // starts the loop, stops it when this leaves composition
    val peer = remember(peerBase58) { /* client.parseAddress(...) off the main thread, or pass bytes */ }
    if (peer != null) HopConversationScreen(client, peer)
}
```

`rememberHopClient` binds a `HopClient` to the composition: it starts the tick loop and closes the engine
on dispose. `HopConversationScreen` is batteries-included (history + composer); or compose your own screen
from `client.state` (a `StateFlow<HopClientState>`) and `client.inbox` (a hot `Flow` of new arrivals).

## Sending

```kotlin
when (val r = client.sendText(peer, "meet at the ridge")) {
    is HopSendResult.Accepted -> Unit          // shown immediately as "sending", then advances on its own
    is HopSendResult.Rejected -> showError(r.reason)
}
```

The message appears in `state` optimistically as `HopDelivery.Pending`, and the loop advances it to
`Relayed` then `Delivered` as acks come back. `send(...)` is the untraceable path: no address on the wire.

## Wiring the engine

### Android / Desktop (JVM)

Bring a `HopNode` from the `sh.hop:hop` node SDK (`sdk/android` in the Hop monorepo) and wrap it
with the ready-made adapter in [`examples/jvm/JnaHopEngine.kt`](./examples/jvm/JnaHopEngine.kt) (copy it
into your app; it is shipped as an example so the library itself stays binding-neutral):

```kotlin
import sh.hop.HopNode
import sh.hop.compose.examples.jvm.JnaHopEngine

val node = HopNode.openKeyed(dbPath, keystoreKey)!!   // encrypted at rest
node.setName("Ada's Pixel")
val engine = JnaHopEngine(node)                         // -> HopEngine, hand to rememberHopClient
```

### iOS

The Apple node lives in the [`sdk/apple`](https://github.com/hopmesh/hop-sdk-apple) xcframework your app
already links. Implement `HopEngine` as a thin adapter over your Swift Hop node (the same handful of
forwarding calls `JnaHopEngine` makes on the JVM) and pass it to `rememberHopClient`. Nothing above the
seam changes.

## What you get

- **Reactive, not polled.** `HopClient` owns the tick loop; you observe `StateFlow<HopClientState>`.
  Conversations are grouped by peer and ordered for you; the reducer is the single source of truth.
- **Optimistic sends with live delivery.** Outbound messages render instantly and advance through
  `Pending -> Relayed -> Delivered` as the node reports status.
- **Cross platform for real.** The client, the state, and every composable are `commonMain`. Only the wall
  clock and the JVM engine adapter are platform code.
- **Testable without a device.** The `HopEngine` seam means the whole reactive surface is verified against
  a fake engine (`gradle allTests`), no libhop required.

## Status

Prototype. The reactive client, the pure state reducer, the value types, and the Compose composables are
built and unit-tested against a fake engine (`gradle allTests`, no native library needed). The engine
adapters are app-supplied examples: `examples/jvm/JnaHopEngine.kt` for Android and Desktop over the
`sh.hop:hop` node SDK, and an Apple-xcframework adapter on iOS. Iterating in the open.

## The Hop family

Same node, your language. The SDKs:
[node](https://www.npmjs.com/package/@hop-mesh/endpoint) &middot;
[python](https://pypi.org/project/hop-endpoint/) &middot;
[go](https://github.com/hopmesh/hop-sdk-go) &middot;
[ruby](https://rubygems.org/gems/hop-endpoint) &middot;
[crystal](https://github.com/hopmesh/hop-sdk-crystal) &middot;
[elixir](https://hex.pm/packages/hop_endpoint) &middot;
[apple](https://github.com/hopmesh/hop-sdk-apple) &middot;
android &middot;
compose.
The protocol core:
[hop-mesh-core](https://crates.io/crates/hop-mesh-core) /
libhop /
[@hop-mesh/wasm](https://www.npmjs.com/package/@hop-mesh/wasm).
The in-tree crate is hop-core, published under the hop-mesh- prefix. The Android and Compose SDKs are
not published yet, and libhop is the C ABI it exposes, not a separate release.

## License

[Apache-2.0](./LICENSE.md), embed it freely. The protocol core it binds (`hop-core`) stays FSL-1.1-ALv2,
source-available and converting to Apache-2.0 after two years.
