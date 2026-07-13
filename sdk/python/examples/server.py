"""A standalone, self-hostable Hop endpoint (the two-process deployment shape). Run this, then run
client.py with the address it prints. In production HNS would resolve a name to this host/port/key, and
you would persist the key so the address is stable across restarts."""
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from hop_endpoint import HopEndpoint, listen  # noqa: E402

port = int(os.environ.get("PORT", "9944"))

server = HopEndpoint()


@server.on("acme/orders")
def handle(req, reply):
    # req.from_addr is the cryptographically VERIFIED sender, not a spoofable header. No auth middleware.
    print(f"[server] {req.service}/{req.method} from {req.from_addr[:12]}: {req.text}", flush=True)
    reply(201, json.dumps({"ok": True, "received": json.loads(req.args)}).encode())


listen(server, port)
print(f"hop endpoint listening on tcp://0.0.0.0:{port}", flush=True)
print(f"address: {server.address}", flush=True)
print(f"\ntry it:\n  python3 examples/client.py {server.address} localhost {port}", flush=True)

while True:  # keep the endpoint (and its daemon pump thread) alive
    time.sleep(3600)
