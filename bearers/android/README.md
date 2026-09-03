<p align="center">
  <img alt="Hop" src="https://hopme.sh/hop-mark.svg" width="200">
</p>

<h1 align="center">Hop Bearers for Android</h1>

<p align="center">
  <b>The radios Hop rides on Android: BLE, LAN, and cloud relay, as independent Gradle modules.</b><br>
  Each bearer moves opaque bytes between two peers and conforms to one small contract, so a node plugs in only the transports it wants.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Kotlin-2.2-7F52FF" alt="Kotlin 2.2">
  <img src="https://img.shields.io/badge/Android-minSdk%2029-3ddc84" alt="Android minSdk 29">
  <img src="https://img.shields.io/badge/license-Apache--2.0-3ddc84" alt="license Apache-2.0">
</p>

---

Hop is a **delay-tolerant, end-to-end-encrypted mesh**: messages hop device to device over BLE, Wi-Fi,
and the internet until they reach the person or service you meant. Held, never dropped.

**Hop Bearers for Android is the transport layer.** Independent Android library modules (BLE, LAN, cloud
relay, Meshtastic/LoRa) each discover peers, form links, and shuttle application bytes, and each
implements the same tiny `Bearer` / `LinkSink` contract from the Kotlin SDK. The bearer owns the radio
and its own dedup; the core never sees a socket, and you pull in only the pipes you need.

## What's in the box

| Module          | Transport   | How it works                                                        |
| --------------- | ----------- | ------------------------------------------------------------------- |
| `bearer-ble`        | BLE         | GATT carries the PSM handshake, L2CAP carries data, iBeacon wakes the app |
| `bearer-lan`        | Wi-Fi / LAN | NSD `_hoplan._tcp` discovery over TCP                               |
| `bearer-relay`      | Internet    | one outbound WebSocket to a relay (OkHttp, no inbound port)         |
| `bearer-meshtastic` | LoRa mesh   | relays through a connected Meshtastic radio: fragments frames into mesh packets on a private app port |

## Install

The bearers aren't published. Nothing under `sh.hop.bearers` is on Maven Central, so there is no
coordinate to depend on: they're consumed as sibling Gradle modules inside the Hop monorepo, one module
per transport, and you include only the ones you want (`minSdk` 29, the floor for L2CAP CoC). The `../`
depth below is from `apps/android/HopDemo`, adjust for wherever yours sits:

```kotlin
// settings.gradle.kts
include(":hop-sdk", ":bearer-ble", ":bearer-lan", ":bearer-relay", ":bearer-meshtastic")
project(":hop-sdk").projectDir            = file("../../../bearers/android/hop-sdk")
project(":bearer-ble").projectDir         = file("../../../bearers/android/bearer-ble")
project(":bearer-lan").projectDir         = file("../../../bearers/android/bearer-lan")
project(":bearer-relay").projectDir       = file("../../../bearers/android/bearer-relay")
project(":bearer-meshtastic").projectDir  = file("../../../bearers/android/bearer-meshtastic")
```

```kotlin
// build.gradle.kts
dependencies {
    implementation(project(":bearer-ble"))
    implementation(project(":bearer-lan"))
    implementation(project(":bearer-relay"))
    implementation(project(":bearer-meshtastic"))
}
```

Every bearer declares `implementation(project(":hop-sdk"))`, the in-tree shim that compiles
`sdk/android`'s shared source; that is what carries the `Bearer` / `LinkSink` / `HopRole` contract and
the registry, which is why the snippet above maps it alongside the transports. The publishing convention
in `bearers/android/build.gradle.kts` still names `sh.hop.bearers`, a subgroup of the SDK's own verified
`sh.hop` namespace, for the day these do ship. Kotlin package names are unrelated to Maven coordinates
and stay `sh.hopme.bearers.*`.

## Usage

Register the bearers you want with a `BearerManager` (one `LinkId` space across every radio) and give
it a sink. That's the whole seam:

```kotlin
import sh.hop.BearerManager
import sh.hop.LinkSink
import sh.hopme.bearers.ble.BleBearer
import sh.hopme.bearers.lan.LanBearer
import sh.hopme.bearers.relay.RelayBearer
import sh.hopme.bearers.meshtastic.MeshtasticBearer
import java.security.SecureRandom

val myId = ByteArray(16).also { SecureRandom().nextBytes(it) }

val mesh = BearerManager()
mesh.register(BleBearer(context, myId))          // GATT PSM handshake, L2CAP data, iBeacon wake
mesh.register(LanBearer(context, myId))          // NSD _hoplan._tcp + TCP
mesh.register(RelayBearer("wss://relay.hopme.sh/"))
mesh.register(MeshtasticBearer(context, myId))   // relay through a connected Meshtastic LoRa radio

mesh.sink = myConsumer                         // gets linkUp / linkBytes / linkDown
mesh.start()

// later, send opaque bytes on a live link; the core owns every byte of crypto
mesh.send(packet, linkId)
```

In a real app the sink is a Hop node: `HopRuntime` (in the Kotlin SDK) wires a `BearerManager` to a
`hop-core` node so every link drives the node and the node's outbound packets route back to the owning
bearer. `BearerManager.start()`/`stop()` isolate each bearer, so BLE failing to listen (radio off at
launch) can't abort LAN or relay.

## The contract

A bearer names nothing about BLE, Wi-Fi, or sockets. It reports three things and accepts `send`:

```kotlin
interface LinkSink {
    fun linkUp(link: Long, role: HopRole, peerId: ByteArray)
    fun linkBytes(link: Long, bytes: ByteArray)
    fun linkDown(link: Long)
}

interface Bearer {
    var sink: LinkSink?
    val transportName: String       // short UI tag: "BT" / "LAN" / "Relay"
    fun start()
    fun stop()
    fun send(bytes: ByteArray, link: Long)
}
```

The Noise XX handshake that authenticates both ends lives inside the node, not the bearer, so a bearer
carries ciphertext it can't read.

## Status

Prototype. The pure link, dedup, and handshake logic (dial backoff, keep-rule, the framing and dispatch
loop, the iBeacon layout) is extracted into headless classes and unit-tested (JUnit + Robolectric)
under an 80% floor. The device-bound BLE radio classes that neither Robolectric nor an emulator can run
are excluded from the coverage denominator and exercised on real hardware instead. BLE reliability
follows the Ditto design: GATT only for the PSM handshake, data always on L2CAP.

## The Hop family

Hop is one protocol with many faces. The endpoint SDKs, same surface in your language:
[node](https://www.npmjs.com/package/@hop-mesh/endpoint) ·
[python](https://pypi.org/project/hop-endpoint/) ·
[go](https://github.com/hopmesh/hop-sdk-go) ·
[ruby](https://rubygems.org/gems/hop-endpoint) ·
[crystal](https://github.com/hopmesh/hop-sdk-crystal) ·
[elixir](https://hex.pm/packages/hop_endpoint) ·
[apple](https://github.com/hopmesh/hop-sdk-apple) ·
android.
The protocol core is [hop-mesh-core](https://crates.io/crates/hop-mesh-core), which is the in-tree
`hop-core` crate under its published name, plus libhop.
The unlinked ones live in the Hop monorepo and aren't separately published yet.

## License

[Apache-2.0](./LICENSE.md), use it freely. Only the protocol core (`hop-core`) is FSL-1.1-ALv2,
source-available and converting to Apache-2.0 after two years.
