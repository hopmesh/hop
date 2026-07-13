"""Calls a self-hosted Hop endpoint over TCP. The address would normally come from an HNS lookup; here
you paste the one server.py printed.

    python3 examples/client.py <server-address> [host] [port]
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from hop_endpoint import HopEndpoint, dial  # noqa: E402

if len(sys.argv) < 2:
    print("usage: python3 examples/client.py <server-address> [host] [port]", file=sys.stderr)
    sys.exit(2)
address = sys.argv[1]
host = sys.argv[2] if len(sys.argv) > 2 else "localhost"
port = int(sys.argv[3]) if len(sys.argv) > 3 else 9944

client = HopEndpoint()
dial(client, host, port)

try:
    status, body = client.request(address, "acme/orders", "create", json.dumps({"item": "widget", "qty": 3}))
    print(f"<- {status} {body.decode()}")
except Exception as e:  # noqa: BLE001
    print(f"request failed: {e}", file=sys.stderr)
    sys.exit(1)
finally:
    client.close()
