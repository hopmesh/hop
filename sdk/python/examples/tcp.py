"""Proves the Internet bearer: a server endpoint LISTENS on TCP, a client DIALS it over a real socket,
and the hops:// round trip completes over TCP with real Noise. One process, real loopback sockets."""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from hop_endpoint import HopEndpoint, dial, listen  # noqa: E402

PORT = 9948

server = HopEndpoint()


@server.on("acme/orders")
def handle(req, reply):
    print(f"  [server] {req.service}/{req.method} over TCP: {req.text}")
    reply(201, json.dumps({"ok": True, "item": json.loads(req.args)["item"]}).encode())


listen(server, PORT)
print(f"server listening on tcp://localhost:{PORT}  addr={server.address[:12]}")

client = HopEndpoint()
dial(client, "localhost", PORT)  # in production: HNS resolves name -> host/port/key

status, body = client.request(server.address, "acme/orders", "create", json.dumps({"item": "widget"}))
print(f"  [client] <- {status} {body.decode()}")

parsed = json.loads(body)
ok = status == 201 and parsed["ok"] and parsed["item"] == "widget"
server.close()
client.close()
print("\nPASS: hops:// round trip over a real TCP Internet bearer." if ok else "\nFAIL")
sys.exit(0 if ok else 1)
