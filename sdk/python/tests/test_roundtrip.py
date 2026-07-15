"""Round-trip proofs: hops:// request/response in-process and over a real TCP bearer. Stdlib only."""
import socket
import struct
import threading
import unittest

from hop_endpoint import HopEndpoint, connect_in_process, dial, listen
from hop_endpoint.tcp_bearer import MAX_FRAME_BYTES, _recv_loop
from hop_endpoint.wss_bearer import _read_frame


class RoundTrip(unittest.TestCase):
    def test_wss_oversized_header_rejected_before_body_read(self):
        class HeaderOnly:
            def __init__(self):
                self.parts = [b"\x82\x7f", struct.pack(">Q", MAX_FRAME_BYTES + 1)]
            def recv_exact(self, n):
                part = self.parts.pop(0)
                if len(part) != n:
                    raise AssertionError("unexpected body read")
                return part
        with self.assertRaises(ConnectionError):
            _read_frame(HeaderOnly())

    def test_tcp_oversized_header_closes_without_body(self):
        left, right = socket.socketpair()
        delivered = []
        class FakeEndpoint:
            def _deliver(self, *_):
                delivered.append(True)
            def _link_down(self, _):
                pass
        worker = threading.Thread(target=_recv_loop, args=(FakeEndpoint(), left, 1))
        worker.start()
        right.sendall(struct.pack(">I", MAX_FRAME_BYTES + 1))
        worker.join(1)
        self.assertFalse(worker.is_alive())
        self.assertFalse(delivered)
        left.close()
        right.close()

    def test_in_process(self):
        server, client = HopEndpoint(), HopEndpoint()
        server.on("acme/orders", lambda req, reply: reply(200, b"got:" + req.args))
        connect_in_process(server, client)
        try:
            status, body = client.request(server.address_bytes, "acme/orders", "create", b"temp=21")
            self.assertEqual(status, 200)
            self.assertEqual(body, b"got:temp=21")
        finally:
            server.close()
            client.close()

    def test_tcp_bearer(self):
        server = HopEndpoint()
        server.on("acme/orders", lambda req, reply: reply(201, req.args))
        listen(server, 9949)
        client = HopEndpoint()
        dial(client, "localhost", 9949)
        try:
            status, body = client.request(server.address, "acme/orders", "create", b"widget")
            self.assertEqual(status, 201)
            self.assertEqual(body, b"widget")
        finally:
            server.close()
            client.close()


class Cluster(unittest.TestCase):
    def test_join_and_quorum(self):
        # Cluster join + TTL visibility threshold bindings resolve against libhop and behave. The
        # cross-replica dedup + hold are proven in the Rust crate; here we exercise the Python surface.
        e = HopEndpoint(cluster="shared-cluster-passphrase", quorum=3)
        try:
            self.assertEqual(e.cluster_members, 1)
            self.assertIs(e.cluster_quorum(2), e)  # chainable
        finally:
            e.close()


if __name__ == "__main__":
    unittest.main()
