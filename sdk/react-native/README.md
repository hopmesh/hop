# @hop-mesh/react-native

Run a **Hop** mesh node inside a React Native app. Hop is a delay-tolerant, untraceable-by-default mesh
messenger: peers exchange forward-secret messages directly over local transports (BLE, LAN) and via
relays, with no phone number, no account, and no central server that can see who is talking to whom.

This package is the **cross-platform client SDK**. One TypeScript API sits over the two native Hop
client SDKs, so your JavaScript talks to the same protocol core on both platforms:

- **iOS / macOS**: the Swift SDK (`Hop`, from `hop-sdk-apple`).
- **Android**: the Kotlin SDK (`sh.hop:hop`, from `hop-sdk-android`), which bundles the native `libhop`.

The protocol, the crypto, and the wire format all live in that native core; this package only marshals
values across the React Native bridge and gives you an idiomatic, promise-based surface.

## Status: not published yet

This package is **not on npm**. It lives in the Hop monorepo at `sdk/react-native` while the
cross-platform approach is being reworked, so there is no published release and no mirror repository.
To try it, depend on the directory from a local checkout:

```sh
npm install /path/to/monorepo/sdk/react-native
```

`react` and `react-native` are peer dependencies. This library ships native code, so it needs a custom
native build: it does **not** run in Expo Go (use a development build or a bare app).

### iOS

The Apple SDK is three pods, one per Swift Package Manager target, so declare them in your `Podfile`
alongside this package. CocoaPods cannot resolve a Swift Package Manager dependency, which is why they
exist:

```ruby
platform :ios, '16.0'   # the Hop Apple SDK's floor, and therefore this module's

target 'YourApp' do
  # Point at a checkout of the monorepo, or at vendored copies. NOT at a raw URL: every one of these
  # podspecs reads Package.swift from its own directory while CocoaPods evaluates it, and CHop reads
  # LICENSE.md too, and a :podspec URL fetches one file to a temp directory, so it dies on the first
  # read. Verified: evaluating CHop.podspec in isolation fails at line 19 on the missing Package.swift.
  pod 'CHop',        :podspec => '../vendor/hop-sdk-apple/CHop.podspec'
  pod 'HopContract', :podspec => '../vendor/hop-sdk-apple/HopContract.podspec'
  pod 'HopSDK',      :podspec => '../vendor/hop-sdk-apple/HopSDK.podspec'
end
```

The `../vendor/hop-sdk-apple/` directory needs five files kept side by side, copied from `sdk/apple/`
in the `hopmesh/hop` monorepo at the revision you want: the three `.podspec` files, `Package.swift`,
and `LICENSE.md`. The last two are not optional; the podspecs read them at evaluation time. Vendoring
also gives you the immutable pin a URL cannot, since the `hopmesh/hop` repository carries no tags.
That is what the first consumer app did.

```sh
cd ios && pod install
```

What the three are, and why the names look the way they do:

| pod | what it carries | module |
|---|---|---|
| `CHop` | the compiled core, `libhop.xcframework`, downloaded from the pinned release and checksum verified | `CHop` |
| `HopContract` | the pure Swift bearer contract, no native code | `HopContract` |
| `HopSDK` | `HopNode` and `HopRuntime`, the SDK proper | `Hop` |

`HopSDK` exposes the module `Hop`, so `import Hop` is what you write. The POD is not called `Hop` because a
pod by that name builds `libHop.a`, which on a case-insensitive filesystem is the same file name as the
core's `libhop.a`, and the linker then resolves `-lhop` to the wrong archive. That produced two different
broken builds before the pods were renamed, so the split is deliberate.

This replaces an earlier instruction to add the `hop-sdk-apple` Swift package to your app target by hand.
That never worked for this module: the podspec's `s.spm_dependency` call was guarded by
`if s.respond_to?(:spm_dependency)`, the method does not exist in CocoaPods 1.17, and the guard skipped
silently, so `import Hop` could not resolve no matter what the app target contained.
**Note:** the podspecs' `s.source` references git tags in the `hop-sdk-apple` repository, which carries
`v0.0.1` and `v0.0.2` but no podspecs at either tag or on `main`. That affects remote consumption of
`HopMesh` itself; a development pod by local path is unaffected.

**Why not a URL.** An earlier version of this section pointed at
`raw.githubusercontent.com/hopmesh/hop/main/sdk/apple/*.podspec`. Those URLs resolve, and that is all
they do: `pod install` still fails, because each podspec `File.read`s `Package.swift` from its own
directory during evaluation, `CHop` reads `LICENSE.md` as well, and a `:podspec` URL fetches one file
to a temp directory with neither beside it. Evaluating `CHop.podspec` in isolation fails on line 19,
the first read. Do not put those URLs back without also changing the podspecs to stop reading siblings.

### Android

Autolinking wires the module in. The Hop Android SDK (`sh.hop:hop`) is pulled from a local Maven repository (see [React Native Quickstart](../../docs/react-native-quickstart.md)), not from Maven Central, and ships the `libhop` native slices for every ABI, so there is nothing else to configure.

## Quick start

```ts
import { Hop } from "@hop-mesh/react-native";

// A fresh, in-memory identity. Use Hop.open({ dbPath }) for a persistent on-device store,
// or Hop.open({ dbPath, key }) to encrypt that store at rest with a keystore key.
const node = await Hop.ephemeral();
await node.setName("Ada");

// Receive: start the pump, then subscribe. Inbox items repeat until you accept them.
await node.start();
node.onMessage(async (msg) => {
  console.log(`from ${msg.from}: ${new TextDecoder().decode(msg.body)}`);
  await node.acceptInbox(msg.id);
});

// Send an untraceable message to a base58 address.
const bundleId = await node.send({ to: peerAddress, body: "hello mesh" });
if (bundleId) {
  const status = await node.status(bundleId);
  console.log(status.delivered ? "delivered" : `relayed to ${status.relayed}`);
}

// Your own address, to share out of band.
console.log(await node.address());
```

### Moving bytes: the bearer seam

The client SDK owns the protocol but not the radios. To actually transmit, drive a transport from your
app: subscribe to `onOutgoing` to get packets the core wants sent, and feed inbound bytes back with
`bytesReceived`. Bring links up and down as peers connect and disconnect.

```ts
node.onOutgoing(({ link, bytes }) => myTransport.send(link, bytes));
await node.linkUp(linkId, "dialer");         // a peer connected (we dialed)
myTransport.onData((link, bytes) => node.bytesReceived(link, bytes));
await node.linkDown(linkId);                  // the peer went away
```

If you want batteries-included BLE and LAN bearers rather than wiring your own, that is what the Hop
**driver** layer provides on each native platform; this SDK is the lower-level node surface.

### hops:// request/response

A node can also act as a service and answer addressed requests:

```ts
node.onServiceRequest(async (req) => {
  await node.sendServiceResponse({ to: req.from, forRequestId: req.requestId, status: 200, body: "pong" });
});

const requestId = await node.sendServiceRequest({ to: svc, service: "echo", method: "GET", args: "ping" });
node.onServiceResponse(async (res) => {
  if (res.status === 200) console.log(new TextDecoder().decode(res.body));
  await node.acceptServiceResponse(res.forRequestId);
});
```

### hps:// group chat and broadcast channels

A group message here is not one-to-one fan-out and not a multicast bundle. It is a single
content-key-encrypted, per-writer-signed publication, flooded once, so posting to three hundred members
costs what posting to three does. Membership, invites and revocation are properties of the topic's key
handoff, never of the delivery.

A **channel** is group chat: every member holds the shared content key and writes, and each post is
signed by the writer's own identity so readers see a verified sender. A **service** is broadcast: only
the host can produce a post subscribers will verify, even if the read key leaks.

```ts
// Host a channel. Access is "open" | "requestToJoin" | "invite"; visibility is "private" | "discoverable".
// A channel resolves an EMPTY Uint8Array (it has no service signing key); a service resolves its public
// verify key. null means the register failed, which is not the same thing.
await node.hpsRegister("town/square", "channel", "requestToJoin", "discoverable");

// Join someone else's topic, then post to it.
await node.hpsSubscribe(hostAddress, "town/square");
await node.hpsPublish("town/square", "hello channel");

// Receive. Publications repeat on every poll until you accept them, exactly like the inbox.
node.onHpsMessage(async (msg) => {
  console.log(`${msg.path} <- ${msg.sender}: ${new TextDecoder().decode(msg.body)}`);
  await node.acceptHpsMessage(msg.id);
});

// Invites are take-and-clear, not accept-to-remove: persist what this hands you or it is gone.
node.onHpsInvite((inv) => saveInvite(inv));
await node.hpsAcceptInvite(inv.host, inv.path);

// Hosting a requestToJoin topic: approve or deny, and revoke by rotating the key without them.
for (const requester of await node.hpsPending("town/square")) await node.hpsApprove("town/square", requester);
await node.hpsRekey("town/square", "", [addressToRevoke]);
```

`hpsMyTopics()` rebuilds your topic list from the node's own store at startup, and `hpsBrowse()` finds
discoverable topics on the mesh. Only topics hosted by apps holding the same app secret are ever
surfaced, so one app's channels are invisible to another's.

### Relays: a pool, not one URL

A single hardcoded relay URL is a single point of failure. Offer the node every endpoint you know and
let it score them:

```ts
await node.relayAdd("wss://relay.example/hop");   // `configured` defaults to true: an operator choice
const url = await node.relayNext();               // the one to dial now, or null
await node.relayReport(url, ok);                  // scores it: success clears backoff, failure extends it
```

`relayNext()` resolving null is two different states, and a UI must tell them apart. With a non-zero
`(await node.relayPool()).total` it means every candidate is currently backed off: show that, and retry,
because the backoff always eventually recovers. With a zero total the pool is simply empty, which is what
`relayAdd` fixes.

## API

- `Hop.ephemeral()`, `Hop.withSecret(secret)`, `Hop.open({ dbPath, secret?, appSecret?, key? })` create a `HopNode`.
- `HopNode`: `address()`, `secret()`, `setName()`, `subscribe()`, `publishPrekey()`, `isSecured()`,
  `send()`, `sendTo()`, `status()`, `acceptInbox()`, the `sendServiceRequest`/`sendServiceResponse`
  surface, the hps:// surface (`hpsRegister`/`hpsSubscribe`/`hpsPublish`/`acceptHpsMessage`,
  `hpsInvite`/`hpsAcceptInvite`/`hpsDeclineInvite`/`hpsLeave`, the host controls
  `hpsPending`/`hpsApprove`/`hpsDeny`/`hpsRekey`/`hpsReach`/`hpsMembers`, and
  `hpsMyTopics`/`hpsBrowse`), the relay pool (`relayAdd`/`relayNext`/`relayReport`/`relayPool`), the
  bearer seam (`linkUp`/`linkDown`/`bytesReceived`), `start()`/`stop()`, the
  `onMessage`/`onServiceRequest`/`onServiceResponse`/`onOutgoing`/`onHpsMessage`/`onHpsInvite`
  subscriptions, and `close()`.
- `HopAddress.toBase58(bytes)` / `HopAddress.fromBase58(text)` convert between raw 32-byte addresses and
  their base58 form.

Addresses are base58 strings; message bodies accept a `Uint8Array` or a UTF-8 string; ids are
`Uint8Array`s. See the TypeScript types for the full surface.

## Compatibility

The module uses the classic React Native bridge, which runs on both the old and the New Architecture
(via the interop layer). React Native 0.71+.

## License

Apache-2.0. See [LICENSE.md](./LICENSE.md).
