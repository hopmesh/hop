"""Proves the full DNS-free discovery chain: a client resolves a domain by name, the TLS cert proves the
domain (WebPKI), the served reach record self-certifies the address, and the WSS handshake confirms it,
then a hops:// round trip runs over the WebSocket. One process, a real self-signed HTTPS server
(production uses a real cert; here we accept the in-process self-signed one with insecure_tls).

Needs the dev/example dependency `cryptography` for the in-process cert: pip install cryptography
(or `pip install -e '.[dev]'`). The endpoint SDK itself stays zero-dep."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from hop_endpoint import HopEndpoint  # noqa: E402
from hop_endpoint.dev_tls import server_context  # noqa: E402

PORT = 8443
PUBLIC = f"wss://localhost:{PORT}/_hop"

# self-signed cert for localhost, generated IN-PROCESS (no openssl CLI); production has a real WebPKI cert
ctx = server_context()

# --- the server: an HTTPS server (wss /_hop + GET /.well-known/hop), wired in ONE call ---
server = HopEndpoint()
server.on("acme/orders", lambda req, reply: (
    print(f"  [server] {req.service}/{req.method} from {req.from_addr[:10]}: {req.text}"),
    reply(201, req.args),
)[-1])
server.attach("127.0.0.1", PORT, ctx, PUBLIC)
print(f"endpoint on https://localhost:{PORT} (well-known + wss)  addr={server.address[:12]}")

# --- the client: resolve by NAME, verifying the record, then round-trip over WSS ---
client = HopEndpoint()
address = client.dial_by_name(f"https://localhost:{PORT}", insecure_tls=True)
print(f"  [client] resolved the domain -> {address[:12]} (reach record verified)")

status, body = client.request(address, "acme/orders", "create", b"widget")
print(f"  [client] <- {status} {body.decode()}")

ok = status == 201 and body == b"widget"
server.close()
client.close()
print("\nPASS: name -> verified address -> WSS hops:// round trip." if ok else "\nFAIL")
sys.exit(0 if ok else 1)
