<p align="center">
  <img alt="Hop" src="https://hopme.sh/hop-mark.svg" width="200">
</p>

<h1 align="center">hop-endpoint</h1>

<p align="center">
  <b>Receive Hop messages in your Python service.</b><br>
  A Flask/FastAPI-shaped endpoint on the <a href="https://hopme.sh">Hop</a> mesh, over the <code>libhop</code> C ABI.
</p>

<p align="center">
  <a href="https://pypi.org/project/hop-endpoint/"><img src="https://img.shields.io/pypi/v/hop-endpoint?color=3776ab&label=pypi" alt="pypi"></a>
  <img src="https://img.shields.io/badge/license-Apache--2.0-3ddc84" alt="license">
  <img src="https://img.shields.io/badge/python-%E2%89%A53.9-6ea8fe" alt="python >=3.9">
</p>

---

Hop is a **delay-tolerant mesh**: end-to-end encrypted datagrams that hop device to device, over BLE,
Wi-Fi, and the internet, until they reach the person or service you meant. Held, never dropped.

`hop-endpoint` is the **server side**: your Python service becomes a first-class address on the mesh, so
senders hand messages straight to it. Self-host is an import, not an ops project. No inbound port to open
to the world, no bearer tokens to rotate, no message queue to run: the sender identity is authenticated
by the ratchet, and delivery is durable and store-and-forward. **Zero runtime deps**, `ctypes` is stdlib.

## Install

```sh
pip install hop-endpoint
```

You also need `libhop`, the Rust protocol core, as a prebuilt binary or a local build, pointed to with
`HOP_LIBDIR`. See [libhop](https://github.com/hopmesh/libhop).

## Quick start

```python
import json
from hop_endpoint import HopEndpoint, listen

hop = HopEndpoint()   # the identity key is the only real config; omit it for an ephemeral address

@hop.on("acme/orders")
def handle(req, reply):
    order = json.loads(req.text)              # req.from_addr is a VERIFIED identity, not a spoofable header
    reply(201, json.dumps({"ok": True, "id": save(order)}))   # uint16 status + str/bytes body

listen(hop, 9944)     # reachable by any device
print(hop.address)    # publish this (or its name); senders reach you by it
```

**The DX looks like HTTP; the semantics are better.** Inbound is a durable, store-and-forward consume; a
reply is a new addressed message that may arrive later, even after a restart. It works when the peer is
offline, and there is no auth layer to bolt on, the identity is cryptographic. core is poll-model, so the
endpoint runs a background pump thread (the node is thread-safe).

## Reachable by name

Make your endpoint reachable at `myaddress.com` with no new port and no DNS records beyond a plain `A`.
`attach` wires the WSS bearer (`/_hop`) and the discovery route (`/.well-known/hop`) in one call:

```python
import ssl
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain("cert.pem", "key.pem")
hop.attach("0.0.0.0", 443, ctx, "wss://myaddress.com/_hop")
```

A client reaches it by name, verified end to end:

```python
address = client.dial_by_name("https://myaddress.com")
response = client.request(address, "acme/orders", "create", order)
persist_result(response)
response.accept()  # remove the durable response only after local work succeeds
status, body = response.status, response.body
```

TLS proves the domain, a signed **reach record** proves the address, and the Noise handshake confirms it.
Spoof the `A` record or MITM the lookup and the attacker still can't forge the cert or complete the
handshake as the address, and a request sealed to that address is unreadable to anyone else.

## How it maps to the core

The endpoint is a `hop-core` node in host-a-mailbox mode, over the same C ABI every Hop SDK binds, with
zero core changes:

| Endpoint              | libhop C ABI                                               |
| --------------------- | ---------------------------------------------------------- |
| `hop.on(svc, fn)`     | `hop_subscribe` + `hop_poll_service_requests`              |
| `reply(status, body)` | `hop_send_service_response` (status is a `uint16`)         |
| `hop.request(...)`    | `hop_send_service_request` + durable response poll/accept  |
| the Internet bearer   | `hop_link_up` / `hop_bytes_received` / `hop_drain_outgoing`|

## Examples

Point `HOP_LIBDIR` at a built `libhop`, then:

```sh
python -m unittest discover -s tests   # in-process + TCP + reach record + WSS discovery, all pass
python examples/raw_roundtrip.py       # raw C ABI round trip (proves the ctypes bindings)
python examples/echo.py                # the hop.on / reply DX in-process
python examples/tcp.py                 # the same round trip over a real TCP bearer
python examples/discovery.py           # the full reachable-by-name chain (HTTPS + WSS)
```

Two-process shape (a standalone server plus a client that dials it):

```sh
python examples/server.py                    # prints its address, listens on tcp://0.0.0.0:9944
python examples/client.py <address> localhost 9944
```

The discovery example and test use `cryptography` (a dev-only extra, `pip install 'hop-endpoint[dev]'`)
solely to generate an in-process self-signed cert; it is never imported at runtime.

## Status

Prototype. Built and working: the `on` handler (also a decorator) and `reply`, the client `request()`,
the in-process / TCP / WSS bearers, base58 addressing, reach-record `attach` / `dial_by_name` discovery,
sibling-replica clustering, and the ABI-version assert. HNS name publish/resolve and multi-tenant hosting
are on the roadmap (each an SDK-level follow-up, not a core change).

## The Hop family

`hop-endpoint` is one of several SDKs over the same C ABI. Same surface, your language:
[node](https://github.com/hopmesh/hop-sdk-node) ·
[python](https://github.com/hopmesh/hop-sdk-python) ·
[go](https://github.com/hopmesh/hop-sdk-go) ·
[ruby](https://github.com/hopmesh/hop-sdk-ruby) ·
[crystal](https://github.com/hopmesh/hop-sdk-crystal) ·
[elixir](https://github.com/hopmesh/hop-sdk-elixir).
The protocol core is [libhop](https://github.com/hopmesh/libhop) / [hop-core](https://github.com/hopmesh/hop-core).

## License

[Apache-2.0](./LICENSE.md), embed it freely. Only the protocol core (`hop-core`) is FSL-1.1-ALv2,
source-available and converting to Apache-2.0 after two years.
