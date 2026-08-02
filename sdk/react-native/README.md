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

```sh
cd ios && pod install
```

The podspec pulls in the Hop Apple SDK as a Swift Package Manager dependency when your toolchain
supports it (CocoaPods 1.16+, React Native 0.75+). On older toolchains, add the
[`hop-sdk-apple`](https://github.com/hopmesh/hop-sdk-apple) Swift package to your app target in Xcode;
the bridge's `import Hop` then resolves against it.

### Android

Autolinking wires the module in. The Hop Android SDK (`sh.hop:hop`) is pulled from Maven Central and
ships the `libhop` native slices for every ABI, so there is nothing else to configure.

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

## API

- `Hop.ephemeral()`, `Hop.withSecret(secret)`, `Hop.open({ dbPath, secret?, appSecret?, key? })` create a `HopNode`.
- `HopNode`: `address()`, `secret()`, `setName()`, `subscribe()`, `publishPrekey()`, `isSecured()`,
  `send()`, `sendTo()`, `status()`, `acceptInbox()`, the `sendServiceRequest`/`sendServiceResponse`
  surface, the bearer seam (`linkUp`/`linkDown`/`bytesReceived`), `start()`/`stop()`, the
  `onMessage`/`onServiceRequest`/`onServiceResponse`/`onOutgoing` subscriptions, and `close()`.
- `HopAddress.toBase58(bytes)` / `HopAddress.fromBase58(text)` convert between raw 32-byte addresses and
  their base58 form.

Addresses are base58 strings; message bodies accept a `Uint8Array` or a UTF-8 string; ids are
`Uint8Array`s. See the TypeScript types for the full surface.

## Compatibility

The module uses the classic React Native bridge, which runs on both the old and the New Architecture
(via the interop layer). React Native 0.71+.

## License

Apache-2.0. See [LICENSE.md](./LICENSE.md).
