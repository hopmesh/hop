<p align="center">
  <img alt="Hop" src="https://hopme.sh/hop-mark.svg" width="200">
</p>

<h1 align="center">hop_endpoint</h1>

<p align="center">
  <b>Receive Hop messages in your Dart or Flutter app.</b><br>
  A first-class endpoint on the <a href="https://hopme.sh">Hop</a> mesh, over the <code>libhop</code> C ABI via <code>dart:ffi</code>.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/license-Apache--2.0-3ddc84" alt="license">
  <img src="https://img.shields.io/badge/dart-%E2%89%A53.1-0175c2" alt="dart >=3.1">
</p>

---

Hop is a **delay-tolerant mesh**: end-to-end encrypted datagrams that hop device to device, over BLE,
Wi-Fi, and the internet, until they reach the person or service you meant. Held, never dropped.

`hop_endpoint` makes your Dart service or Flutter app a first-class address on the mesh, so senders hand
messages straight to it. No inbound port to open to the world, no bearer tokens to rotate, no message
queue to run: the sender identity is authenticated by the ratchet, and delivery is durable and
store-and-forward. One dependency (`package:ffi`), the same C ABI every Hop SDK binds.

## Install

```sh
dart pub add hop_endpoint
```

You also need `libhop`, the Rust protocol core, as a prebuilt binary or a local build. For `dart test`
and CLI use, point `HOP_LIBDIR` at it (or build in-repo with `cargo build -p hop`). In a Flutter app,
bundle the platform shared library so the loader finds it by name (see [Flutter](#flutter) below). It
is a sibling crate in the Hop monorepo and is not separately published. Dart 3.1+.

## Quick start

```dart
import 'dart:convert';
import 'package:hop_endpoint/hop_endpoint.dart';

Future<void> main() async {
  final hop = HopEndpoint();

  hop.on('acme/orders', (req, reply) {
    // req.from is a VERIFIED identity (base58), not a spoofable header
    final order = jsonDecode(req.text);
    reply(201, jsonEncode({'ok': true, 'order': order})); // uint16 status + body
  });

  await listen(hop, 9944); // reachable by any device
  print(hop.address);      // publish this (or its name); senders reach you by it
}
```

**The DX looks like HTTP; the semantics are better.** Inbound is a durable, store-and-forward consume; a
reply is a new addressed message that may arrive later, even after a restart. It works when the peer is
offline, and there is no auth layer to bolt on, the identity is cryptographic. core is poll-model, so the
endpoint runs a periodic pump on the isolate's event loop (single-threaded, so there is no locking).

## Calling another endpoint

```dart
final resp = await hop.request(address, 'acme/orders', 'create', args: 'widget x3');
print('${resp.status}: ${resp.text}'); // e.g. 201: accepted
```

`request` completes when the response returns (delay-tolerant), or throws `TimeoutException` after its
`timeout` (default 15s). `address` is a base58 string or 32 raw bytes.

## Reachable by name

Make an endpoint reachable at `myaddress.com` with no new port, on `dart:io`'s built-in TLS + WebSocket
(no third-party WebSocket package). `attach` wires the WSS bearer (`/_hop`) and the discovery route
(`/.well-known/hop`) in one call:

```dart
final ctx = SecurityContext()
  ..useCertificateChain('cert.pem')
  ..usePrivateKey('key.pem');
await hop.attach(port: 443, context: ctx, publicUrl: 'wss://myaddress.com/_hop');
```

A client reaches it by name, verified end to end:

```dart
final address = await client.dialByName('https://myaddress.com');
final resp = await client.request(address, 'acme/orders', 'create', args: order);
```

TLS proves the domain, a signed **reach record** proves the address, and the Noise handshake confirms it.
Spoof the `A` record or MITM the lookup and the attacker still cannot forge the cert or complete the
handshake as the address, and a request sealed to that address is unreadable to anyone else.

## Flutter

`hop_endpoint` is pure Dart (no Flutter import), so it drops into a Flutter app unchanged. Package the
`libhop` shared library per platform so the loader resolves it by name: Android `jniLibs/<abi>/libhop.so`,
iOS/macOS an embedded `libhop.dylib` (or a static xcframework), Windows `hop.dll`, Linux `libhop.so`.
Build the node in a long-lived object (an app-level singleton or a `provider`), register your `on(...)`
handlers, and drive a bearer. Keep the endpoint off the UI isolate if you push heavy traffic.

## How it maps to the core

The endpoint is a `hop-core` node in host-a-mailbox mode, over the same C ABI every Hop SDK binds (via
`dart:ffi`), with zero core changes:

| Endpoint                | libhop C ABI                                               |
| ----------------------- | ---------------------------------------------------------- |
| `hop.on(svc, fn)`       | `hop_subscribe` + `hop_poll_service_requests`              |
| `reply(status, body)`   | `hop_send_service_response` (status is a `uint16`)         |
| `hop.request(...)`      | `hop_send_service_request` + `hop_poll_service_responses`  |
| the Internet bearer     | `hop_link_up` / `hop_bytes_received` / `hop_drain_outgoing`|

## Examples

Point `HOP_LIBDIR` at a built `libhop`, then:

```sh
dart test                          # in-process + TCP + reach + WSS discovery, all pass
dart run example/raw_roundtrip.dart # raw C ABI round trip (proves the dart:ffi bindings)
dart run example/echo.dart          # the hop.on / reply DX in-process
dart run example/tcp.dart           # the same round trip over a real TCP bearer
dart run example/discovery.dart     # the full reachable-by-name chain (HTTPS + WSS)
```

Two-process shape (a standalone server plus a client that dials it):

```sh
dart run example/server.dart                    # prints its address, listens on tcp://0.0.0.0:9944
dart run example/client.dart <address> localhost 9944
```

## Status

Prototype. Built and working: the `on` handler and `reply`, the client `request`, the in-process / TCP /
WSS bearers, base58 addressing, reach-record `attach` / `dialByName` discovery, sibling-replica
clustering, the ABI-version assert, and a use-after-free-safe `close` (bearer callbacks that fire after
teardown short-circuit instead of touching a freed node). HNS name publish/resolve and multi-tenant
hosting are on the roadmap (each an SDK-level follow-up, not a core change).

## The Hop family

`hop_endpoint` is one of several SDKs over the same C ABI. Same surface, your language:
[node](https://www.npmjs.com/package/@hop-mesh/endpoint) &middot;
[python](https://pypi.org/project/hop-endpoint/) &middot;
[go](https://github.com/hopmesh/hop-sdk-go) &middot;
[ruby](https://rubygems.org/gems/hop-endpoint) &middot;
[crystal](https://github.com/hopmesh/hop-sdk-crystal) &middot;
[elixir](https://hex.pm/packages/hop_endpoint) &middot;
flutter.
The protocol core is libhop / [hop-mesh-core](https://crates.io/crates/hop-mesh-core).
The in-tree crate is hop-core, published under the hop-mesh- prefix. The Flutter SDK is not published
yet, and libhop is the C ABI it exposes, not a separate release.

## License

[Apache-2.0](./LICENSE.md), embed it freely. Only the protocol core (`hop-core`) is FSL-1.1-ALv2,
source-available and converting to Apache-2.0 after two years.
