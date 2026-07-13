# hop-endpoint (Python endpoint SDK, prototype)

Receive Hop messages in Python with a Flask/FastAPI-shaped surface, over the `libhop` C ABI. Same idea
as `sdk/node` and `sdk/elixir`: your service becomes directly reachable on the mesh, so senders hand
messages straight to it without a relay. **Zero third-party deps**, `ctypes` is in the stdlib.

```python
import json
from hop_endpoint import HopEndpoint, listen

hop = HopEndpoint()

@hop.on("acme/orders")
def handle(req, reply):
    # req.from_addr is a cryptographically VERIFIED identity, not a spoofable header
    order = json.loads(req.args)
    reply(201, json.dumps({"ok": True, "order": order}).encode())   # uint16 status + bytes body

listen(hop, 9944)          # reachable by any device; in production HNS resolves name -> host/port/key
print(hop.address)         # publish this (or its HNS name)
```

## What it is (and isn't)

The endpoint is a `hop-core` node in service-host mode. The mapping onto the C ABI is exact:

| Endpoint concept        | libhop C ABI                                              |
| ----------------------- | --------------------------------------------------------- |
| `hop.on(service, fn)`   | `hop_subscribe` + `hop_poll_service_requests`             |
| `reply(status, body)`   | `hop_send_service_response` (status is a `uint16`)        |
| `hop.request(...)`      | `hop_send_service_request` + `hop_poll_service_responses` |
| the Internet bearer     | `hop_link_up` / `hop_bytes_received` / `hop_drain_outgoing` |

**The DX is HTTP-shaped; the semantics are not.** Inbound is a durable store-and-forward consume; a
reply is a new addressed message that may arrive later, even after a restart. It is a queue consumer,
not a synchronous route, that is what makes it offline-tolerant. core is poll-model, so the endpoint
runs a background pump thread (the node is thread-safe).

## Run the proofs

Build `libhop` first (or set `HOP_LIBDIR`):

```sh
cargo build -p hop                       # from the repo root -> target/debug/libhop.<dylib|so>
cd sdk/python
python3 examples/raw_roundtrip.py        # raw C ABI round trip (proves the ctypes bindings)
python3 examples/echo.py                 # the hop.on / reply DX in-process
python3 examples/tcp.py                  # the same round trip over a real TCP bearer
pip install cryptography                  # the discovery example + test need it (in-process dev cert)
python3 examples/discovery.py            # WSS + WebPKI + reach-record discovery (in-process cert)
python3 -m unittest discover -s tests    # in-process, TCP, reach record, + WSS discovery, all pass
```

Two-process shape (a standalone server + a client that dials it):

```sh
python3 examples/server.py                # prints its address, listens on tcp://0.0.0.0:9944
python3 examples/client.py <address> localhost 9944
```

The endpoint SDK stays **zero runtime deps** (ctypes is stdlib). `cryptography` is a dev/example-only
extra (`pip install -e '.[dev]'`), used solely to generate the in-process self-signed cert for the
discovery example + test; it is never imported at runtime.

## Reachable by name (WSS + discovery)

Make an endpoint reachable at `myaddress.com` with **no new port and no DNSSEC**, using a **pure-stdlib**
WebSocket bearer (zero third-party deps):

```python
import ssl
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain("cert.pem", "key.pem")
hop.attach("0.0.0.0", 443, ctx, "wss://myaddress.com/_hop")   # WSS /_hop + /.well-known/hop in one call
```

```python
address = client.dial_by_name("https://myaddress.com")        # WebPKI + self-certifying
status, body = client.request(address, "acme/orders", "create", order)
```

Trust, no DNSSEC: `dial_by_name` fetches `/.well-known/hop` (TLS proves the domain), verifies the
self-certifying reach record (signed by the address), dials the WSS, and the Noise handshake confirms
the address. `tests/test_discovery.py` proves the full chain against a self-signed HTTPS server.

## Prototype scope

Built and working: `hop.on` (also a decorator), `reply`, `request`, the pump thread, TCP + WSS bearers,
base58 addressing, reach records + `attach`/`dial_by_name` discovery, ABI-version assertion. Follow-ups
(each additive, none a core change): the no-domain gossip case, delegated keys, multi-tenant hosting.
Not yet a required CI job.
Design: `docs/endpoint-sdk.md`.
