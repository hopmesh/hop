<p align="center">
  <img alt="Hop" src="https://hopme.sh/hop-mark.svg" width="200">
</p>

<h1 align="center">Hop for Android</h1>

<p align="center">
  <b>Run a real Hop node on Android.</b><br>
  The Kotlin client SDK for the <a href="https://hopme.sh">Hop</a> mesh, over the <code>libhop</code> C ABI, packaged as a Maven AAR.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/license-Apache--2.0-3ddc84" alt="license">
  <img src="https://img.shields.io/badge/kotlin-2.4-7f52ff" alt="kotlin 2.4">
</p>

---

Hop is a **delay-tolerant mesh**: end-to-end encrypted datagrams that hop device to device, over BLE,
Wi-Fi, and the internet, until they reach the person you meant. Held, never dropped.

This is the **Android client SDK**: it runs a genuine Hop node *on the device*, so a phone is a first-class
peer that relays for everyone else. `HopNode` is a thin, type-safe Kotlin face over `libhop` (the same C
ABI every Hop SDK binds) via JNA, with identity, forward secrecy, and the untraceable send path already
inside. The AAR bundles the native `libhop.so` for every ABI, so there's no NDK build to wire up.

Each release is built from the canonical native-artifact workflow, not from files left on a mirror
runner. `build-aar.sh` verifies the signed source-SHA manifest and independently hashed archives for
`arm64-v8a`, `armeabi-v7a`, `x86`, and `x86_64` before producing the AAR. The Maven publication includes
Prefab metadata and `hop.h`, JNA as an AAR runtime dependency, sources and documentation jars, a full
POM, SHA-256/SHA-512 sidecars, optional in-memory PGP signing, and GitHub provenance attestations.

## Package availability

The source and package pipeline is ready: it publishes the exact standalone export to a clean temporary
Maven repository, resolves the AAR from a separate Android Gradle Plugin application, merges its manifest
and native ABI slices, and assembles an APK offline. Public v0.0.1 publication remains post-merge external state.
This source tree does not assert that a public Maven coordinate or GitHub release exists yet.

## Install after publication

```kotlin
// build.gradle.kts
dependencies {
    implementation("sh.hop:hop:0.0.1")
}
```

## Quick start

`HopNode` is `AutoCloseable` (it owns the native handle), so drive it inside `use { }`:

```kotlin
import sh.hop.HopNode
import sh.hop.HopRole
import sh.hop.HopAddress

// A device-local identity with storage encrypted at rest (SQLCipher, keyed from the Android Keystore).
HopNode.openKeyed(dbPath, keystoreKey)!!.use { node ->
    node.setName("Ada's Pixel")

    // Advance the clock and publish a prekey so peers can open a forward-secret session with you.
    node.tick(System.currentTimeMillis())
    node.publishPrekey()

    // Send an untraceable, end-to-end-encrypted message to a 32-byte address.
    val dst = HopAddress.fromBase58("7Yc9…")!!
    node.send(dst, body = "meet at the ridge".toByteArray(), requestAck = true)

    // Polling is non-destructive. Accept only after your app has persisted the message.
    node.pollInbox { msg ->
        Log.d("hop", "${HopAddress.base58(msg.from)}: ${String(msg.body)}")
        if (appStore.save(msg)) node.acceptInbox(msg.id)
    }
}
```

`send(...)` is the untraceable path (§39): the address is sealed, not on the wire. Use `sendTo(...)` for
a directed send to a connected peer, and `sendServiceRequest`/`sendServiceResponse` for the `hops://`
request/response surface.

## The bearer seam

A node moves opaque bytes; a **bearer** (BLE, LAN, or relay) owns the transport and nothing else. The core
owns all crypto, framing, and routing. Wire a bearer to the node with four calls:

```kotlin
node.linkUp(linkId, HopRole.DIALER)                       // a connection came up (you dialed it)
node.bytesReceived(linkId, inboundFrame)                  // frames the radio delivered, straight in
node.drainOutgoing { link, frame -> radio.send(link, frame) }  // ship queued frames out
node.linkDown(linkId)                                     // the connection dropped
```

## What the node gives you

- **Forward secrecy by default.** Device-to-device content is Double-Ratchet sealed; `isSecured(...)`
  tells you whether a session is live.
- **Untraceable by default.** `send(...)` puts no addresses on the wire; the bundle id is its own
  integrity check.
- **Durable and offline-first.** Messages are stored and forwarded, so a send works when the peer is
  gone and lands later.
- **Encrypted at rest.** `openKeyed` runs SQLCipher over the on-device store; `open` uses plain SQLite
  behind the app sandbox.
- **Identity you own.** `secret()` exports the 32-byte identity to stash in the Keystore; restore with
  `HopNode.withSecret(...)` or `HopNode.open(dbPath, secret)`.

## Status

Prototype. The node surface, the bearer seam, base58 addressing, the `hops://` request/response path,
and encrypted-at-rest storage are built and tested (`gradle test` against a built `libhop`). Iterating in
the open; the wire format and ABI are versioned and asserted at load, so a mismatched build fails loudly
instead of drifting.

## The Hop family

Same node, your language. The SDKs:
[node](https://github.com/hopmesh/hop-sdk-node) ·
[python](https://github.com/hopmesh/hop-sdk-python) ·
[go](https://github.com/hopmesh/hop-sdk-go) ·
[ruby](https://github.com/hopmesh/hop-sdk-ruby) ·
[crystal](https://github.com/hopmesh/hop-sdk-crystal) ·
[elixir](https://github.com/hopmesh/hop-sdk-elixir) ·
[apple](https://github.com/hopmesh/hop-sdk-apple) ·
[android](https://github.com/hopmesh/hop-sdk-android).
The protocol core:
[hop-core](https://github.com/hopmesh/hop-core) /
[libhop](https://github.com/hopmesh/libhop) /
[hop-wasm](https://github.com/hopmesh/hop-wasm).

## License

[Apache-2.0](./LICENSE.md), embed it freely. The protocol core it binds (`hop-core`) stays
FSL-1.1-ALv2, source-available and converting to Apache-2.0 after two years.
