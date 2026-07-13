"""Proofs for reachable-by-name: the reach record, and the full HTTPS well-known + WSS discovery
round trip against a real self-signed HTTPS server."""
import os
import ssl
import subprocess
import tempfile
import time
import unittest

from hop_endpoint import HopEndpoint
from hop_endpoint import _ffi as ffi


def _self_signed():
    d = tempfile.mkdtemp()
    cert, key = os.path.join(d, "cert.pem"), os.path.join(d, "key.pem")
    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-keyout", key, "-out", cert,
         "-days", "1", "-nodes", "-subj", "/CN=localhost"],
        check=True, capture_output=True,
    )
    return cert, key


class ReachRecord(unittest.TestCase):
    def test_sign_verify_and_tamper(self):
        e = HopEndpoint()
        try:
            rec = e.sign_reach("wss://myaddress.com/_hop", 3600)
            info = ffi.verify_reach(rec, int(time.time()))
            self.assertIsNotNone(info)
            self.assertEqual(info["endpoint"], "wss://myaddress.com/_hop")
            self.assertEqual(info["address_b58"], e.address)
            bad = bytearray(rec)
            bad[-1] ^= 0xFF
            self.assertIsNone(ffi.verify_reach(bytes(bad), int(time.time())))
        finally:
            e.close()


class Discovery(unittest.TestCase):
    def test_dial_by_name_round_trip(self):
        port = 8446
        public_url = f"wss://localhost:{port}/_hop"
        cert, key = _self_signed()
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(cert, key)

        server = HopEndpoint()
        server.on("acme/orders", lambda req, reply: reply(201, req.args))
        server.attach("127.0.0.1", port, ctx, public_url)  # WSS + well-known in one call

        client = HopEndpoint()
        try:
            address = client.dial_by_name(f"https://localhost:{port}", insecure_tls=True)
            self.assertEqual(address, server.address)
            status, body = client.request(address, "acme/orders", "create", b"widget")
            self.assertEqual(status, 201)
            self.assertEqual(body, b"widget")
        finally:
            server.close()
            client.close()


if __name__ == "__main__":
    unittest.main()
