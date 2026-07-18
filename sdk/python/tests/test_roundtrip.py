"""Round-trip proofs: hops:// request/response in-process and over a real TCP bearer. Stdlib only."""
import socket
import ssl
import struct
import threading
import unittest
from unittest import mock

from hop_endpoint import HopEndpoint, connect_in_process, dial, listen
from hop_endpoint import _ffi
from hop_endpoint.dev_tls import server_context
from hop_endpoint.endpoint import _Reply
from hop_endpoint.tcp_bearer import MAX_FRAME_BYTES, _recv_loop
from hop_endpoint import wss_bearer
from hop_endpoint.wss_bearer import (
    MAX_HEADER_BYTES,
    MAX_MESSAGE_BYTES,
    MAX_PENDING_CONNECTIONS,
    _read_frame,
    _read_http_head,
    _read_message,
)


class RoundTrip(unittest.TestCase):
    def test_every_fixed_width_argument_requires_exactly_32_bytes(self):
        node = _ffi.node_new()
        try:
            _ffi.tick(node, 1)
            exact = _ffi.address(node)
            for size in (0, 1, 31, 33):
                invalid = b"x" * size
                calls = (
                    lambda: _ffi.accept_inbox(node, invalid),
                    lambda: _ffi.cluster_join(node, invalid),
                    lambda: _ffi.send_service_request(node, invalid, "svc", "get", b""),
                    lambda: _ffi.send_service_response(node, invalid, exact, 200, b""),
                    lambda: _ffi.send_service_response(node, exact, invalid, 200, b""),
                    lambda: _ffi.to_b58(invalid),
                    lambda: HopEndpoint(key=invalid),
                )
                for call in calls:
                    with self.assertRaisesRegex(ValueError, "exactly 32 bytes"):
                        call()

            self.assertFalse(_ffi.accept_inbox(node, exact))
            _ffi.cluster_join(node, exact)
            self.assertEqual(len(_ffi.send_service_request(node, exact, "svc", "get", b"")), 32)
            self.assertTrue(_ffi.send_service_response(node, exact, exact, 200, b""))
            self.assertTrue(_ffi.to_b58(exact))
            keyed = HopEndpoint(key=exact, tick_ms=1000)
            keyed.close()
        finally:
            _ffi.node_free(node)

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

    def test_wss_fragmented_message_cap_is_checked_before_next_body_read(self):
        half = MAX_MESSAGE_BYTES // 2

        class Parts:
            def __init__(self):
                self.parts = [
                    bytes([0x02, 0x7F]),
                    struct.pack(">Q", half + 1),
                    b"a" * (half + 1),
                    bytes([0x80, 0x7F]),
                    struct.pack(">Q", half),
                ]
            def recv_exact(self, n):
                part = self.parts.pop(0)
                if len(part) != n:
                    raise AssertionError(f"unexpected body read: wanted {n}, got {len(part)}")
                return part

        with self.assertRaisesRegex(ConnectionError, "exceeds 1 MiB"):
            _read_message(Parts())

    def test_wss_fragmented_message_at_cap_materializes_once(self):
        half = MAX_MESSAGE_BYTES // 2

        class Parts:
            def __init__(self):
                self.parts = [
                    bytes([0x02, 0x7F]), struct.pack(">Q", half), b"a" * half,
                    bytes([0x80, 0x7F]), struct.pack(">Q", half), b"b" * half,
                ]
            def recv_exact(self, n):
                part = self.parts.pop(0)
                self.assert_size(part, n)
                return part
            @staticmethod
            def assert_size(part, n):
                if len(part) != n:
                    raise AssertionError(f"wanted {n}, got {len(part)}")

        opcode, payload = _read_message(Parts())
        self.assertEqual(opcode, 0x2)
        self.assertEqual(len(payload), MAX_MESSAGE_BYTES)
        self.assertEqual(payload[:1], b"a")
        self.assertEqual(payload[-1:], b"b")

    def test_wss_http_header_cap_is_checked_before_more_input(self):
        class HeaderSocket:
            def __init__(self):
                self.data = b"GET /_hop HTTP/1.1\r\nX: " + b"x" * MAX_HEADER_BYTES
            def settimeout(self, _):
                pass
            def recv(self, n):
                chunk, self.data = self.data[:n], self.data[n:]
                return chunk

        with self.assertRaisesRegex(ConnectionError, "headers exceed"):
            _read_http_head(HeaderSocket())

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

    def test_wss_bounded_workers_recover_after_stalled_and_malformed_handshakes(self):
        class FakeEndpoint:
            def __init__(self):
                self.closers = []
            def _register_closer(self, closer):
                self.closers.append(closer)
            def close(self):
                for closer in self.closers:
                    closer()

        endpoint = FakeEndpoint()
        listener = wss_bearer.serve(endpoint, "127.0.0.1", 0, server_context(), "wss://unused/_hop")
        port = listener.getsockname()[1]
        stalled = socket.create_connection(("127.0.0.1", port))

        def valid_request():
            context = ssl.create_default_context()
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE
            raw = socket.create_connection(("127.0.0.1", port), timeout=2)
            conn = context.wrap_socket(raw, server_hostname="localhost")
            conn.sendall(b"GET /missing HTTP/1.1\r\nHost: localhost\r\n\r\n")
            response = conn.recv(256)
            conn.close()
            return response

        try:
            self.assertIn(b"404 Not Found", valid_request(), "one stalled TLS client blocked all workers")

            context = ssl.create_default_context()
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE
            malformed = context.wrap_socket(
                socket.create_connection(("127.0.0.1", port), timeout=2), server_hostname="localhost"
            )
            malformed.sendall(b"malformed\r\n\r\n")
            malformed.settimeout(2)
            try:
                self.assertEqual(malformed.recv(1), b"")
            except ssl.SSLError:
                pass
            malformed.close()

            self.assertIn(b"404 Not Found", valid_request(), "a malformed first client killed a worker")
        finally:
            stalled.close()
            endpoint.close()

    def test_wss_admission_rejects_cap_plus_one_and_releases_idempotently(self):
        permits = threading.BoundedSemaphore(MAX_PENDING_CONNECTIONS)
        active = set()
        lock = threading.Lock()

        class FakeSocket:
            def close(self):
                pass

        leases = []
        for _ in range(MAX_PENDING_CONNECTIONS):
            self.assertTrue(permits.acquire(blocking=False))
            leases.append(wss_bearer._SocketLease(FakeSocket(), permits, active, lock))
        self.assertFalse(permits.acquire(blocking=False), "cap+1 must be rejected without queueing")
        self.assertEqual(len(active), MAX_PENDING_CONNECTIONS)

        leases[0].release()
        leases[0].release()
        self.assertTrue(permits.acquire(blocking=False), "cleanup must restore exactly one permit")
        permits.release()
        for lease in leases[1:]:
            lease.release()

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

    def test_cluster_calls_hold_node_ownership_until_native_return(self):
        cases = (
            ("join", "cluster_join_passphrase", lambda endpoint: endpoint.cluster("cluster")),
            ("members", "cluster_members", lambda endpoint: endpoint.cluster_members),
            ("quorum", "cluster_set_quorum", lambda endpoint: endpoint.cluster_quorum(2)),
        )
        for label, ffi_name, invoke in cases:
            with self.subTest(label=label):
                endpoint = HopEndpoint(tick_ms=1000)
                entered = threading.Event()
                release = threading.Event()
                closed = threading.Event()
                original = getattr(_ffi, ffi_name)

                def blocked(*args, _original=original):
                    entered.set()
                    self.assertTrue(release.wait(2), "test barrier was not released")
                    return _original(*args)

                with mock.patch.object(_ffi, ffi_name, blocked):
                    call = threading.Thread(target=lambda: invoke(endpoint))
                    call.start()
                    self.assertTrue(entered.wait(1), "native call did not reach the barrier")
                    closer = threading.Thread(target=lambda: (endpoint.close(), closed.set()))
                    closer.start()
                    self.assertFalse(closed.wait(0.05), "close returned while a native call owned the node")
                    release.set()
                    call.join(2)
                    closer.join(2)
                    self.assertFalse(call.is_alive())
                    self.assertFalse(closer.is_alive())
                    self.assertTrue(closed.is_set())

                with self.assertRaisesRegex(RuntimeError, "endpoint is closed"):
                    invoke(endpoint)

    def test_close_from_native_callback_defers_free_until_callback_returns(self):
        endpoint = HopEndpoint(tick_ms=1000)
        events = []
        original_free = _ffi.node_free

        def callback(_node):
            events.append("callback-enter")
            endpoint.close()
            events.append("callback-return")
            self.assertNotIn("free", events)
            return 1

        def record_free(node):
            events.append("free")
            original_free(node)

        with mock.patch.object(_ffi, "cluster_members", callback), mock.patch.object(
            _ffi, "node_free", record_free
        ):
            self.assertEqual(endpoint.cluster_members, 1)

        self.assertEqual(events, ["callback-enter", "callback-return", "free"])
        with self.assertRaisesRegex(RuntimeError, "endpoint is closed"):
            endpoint.cluster_members

    def test_reply_holds_node_ownership_until_native_return(self):
        endpoint = HopEndpoint(tick_ms=1000)
        address = endpoint.address_bytes
        reply = _Reply(endpoint, address, b"r" * 32)
        entered = threading.Event()
        release = threading.Event()
        closed = threading.Event()
        original = _ffi.send_service_response

        def blocked(*args):
            entered.set()
            self.assertTrue(release.wait(2), "test barrier was not released")
            return original(*args)

        with mock.patch.object(_ffi, "send_service_response", blocked):
            call = threading.Thread(target=lambda: reply(200, b"ok"))
            call.start()
            self.assertTrue(entered.wait(1), "reply did not reach the native barrier")
            closer = threading.Thread(target=lambda: (endpoint.close(), closed.set()))
            closer.start()
            self.assertFalse(closed.wait(0.05), "close returned while reply owned the node")
            release.set()
            call.join(2)
            closer.join(2)
            self.assertTrue(closed.is_set())

    def test_public_node_boundaries_fail_deterministically_after_close(self):
        endpoint = HopEndpoint(tick_ms=1000)
        address = endpoint.address_bytes
        reply = _Reply(endpoint, address, b"r" * 32)
        endpoint.close()

        calls = (
            lambda: endpoint.address,
            lambda: endpoint.address_bytes,
            lambda: endpoint.cluster("cluster"),
            lambda: endpoint.cluster_members,
            lambda: endpoint.cluster_quorum(2),
            lambda: endpoint.on("svc", lambda _req, _reply: None),
            lambda: endpoint.request(address, "svc", "get", timeout=0.01),
            lambda: endpoint.sign_reach("wss://example.invalid/_hop"),
            lambda: endpoint.attach("127.0.0.1", 0, None, "wss://example.invalid/_hop"),
            lambda: endpoint.dial_by_name("https://example.invalid"),
            lambda: reply(200, b"closed"),
        )
        for call in calls:
            with self.assertRaisesRegex(RuntimeError, "endpoint is closed"):
                call()


if __name__ == "__main__":
    unittest.main()
