"""Round-trip proofs: hops:// request/response in-process and over a real TCP bearer. Stdlib only."""
import unittest

from hop_endpoint import HopEndpoint, connect_in_process, dial, listen


class RoundTrip(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
