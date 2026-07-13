"""The Flask/FastAPI-shaped DX on real hop-core, in-process. See tcp.py for a real Internet bearer."""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from hop_endpoint import HopEndpoint, connect_in_process  # noqa: E402

server = HopEndpoint()
client = HopEndpoint()


@server.on("acme/orders")
def handle(req, reply):
    print(f"  [server] {req.service}/{req.method} from {req.from_addr[:10]}: {req.text}")
    order = json.loads(req.args)
    reply(201, json.dumps({"ok": True, "id": 42, "item": order["item"]}).encode())


connect_in_process(server, client)
print("server address:", server.address)

status, body = client.request(server.address, "acme/orders", "create", json.dumps({"item": "widget"}))
print(f"  [client] <- {status} {body.decode()}")

parsed = json.loads(body)
ok = status == 201 and parsed["ok"] and parsed["item"] == "widget"
server.close()
client.close()
print("\nPASS: hop.on(service, handler) + reply(status, body) over real hop-core." if ok else "\nFAIL")
sys.exit(0 if ok else 1)
