"""Derisking proof: the hops:// service round trip through the raw C ABI from Python, mirroring
core/hop/src/cabi.rs. Two nodes, a byte-pipe bearer, a request in, 200 + body back out."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from hop_endpoint import _ffi as ffi  # noqa: E402

ffi.assert_abi()
print("ABI ok:", ffi._lib.hop_abi_version())

LA, LB = 11, 22


def drain(node):
    return ffi.drain_outgoing(node)


def pump(a, b):
    for _ in range(1000):
        moved = False
        for _link, buf in drain(a):
            moved = True
            ffi.received(b, LB, buf)
        for _link, buf in drain(b):
            moved = True
            ffi.received(a, LA, buf)
        if not moved:
            break


a = ffi.node_new()
b = ffi.node_new()

# connect(): clock, bearer up (A dials, B accepts), handshake, gossip prekeys
ffi.tick(a, 1000)
ffi.tick(b, 1000)
ffi.connected(a, LA, True)
ffi.connected(b, LB, False)
pump(a, b)
ffi.publish_prekey(a)
ffi.publish_prekey(b)
pump(a, b)
a_addr, b_addr = ffi.address(a), ffi.address(b)
print("A =", ffi.to_b58(a_addr)[:12], " B =", ffi.to_b58(b_addr)[:12])

# A fires a hops:// service request at B
req_id = ffi.send_service_request(a, b_addr, "weather", "report", b"temp=21")
print("request fired, reqId:", req_id.hex()[:12])
pump(a, b)

# B drains the request (the endpoint inbound handler surface)
reqs = ffi.take_service_requests(b)
frm, rid, service, method, args = reqs[0]
print(f"B received: {service}/{method} = {args.decode()} from {ffi.to_b58(frm)[:12]}")

# B replies 200 + body
ffi.send_service_response(b, frm, rid, 200, b"stored")
pump(a, b)

# A drains the response
resps = ffi.take_service_responses(a)
r_from, for_id, status, body = resps[0]
ffi.accept_service_response(a, for_id)
print("A got response:", status, body.decode(), " ties to reqId:", for_id == req_id)

passed = service == "weather" and status == 200 and body == b"stored" and for_id == req_id
ffi.node_free(a)
ffi.node_free(b)
print("\nPASS: full hops:// round trip through the C ABI from Python." if passed else "\nFAIL")
sys.exit(0 if passed else 1)
