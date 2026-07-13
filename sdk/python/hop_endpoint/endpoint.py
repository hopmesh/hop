"""HopEndpoint: receive Hop messages in Python with a Flask/FastAPI-shaped surface, over the libhop
C ABI.

    hop = HopEndpoint()
    @hop.on("acme/orders")
    def handle(req, reply):
        # req.from_addr is a cryptographically VERIFIED identity, not a spoofable header
        reply(201, json.dumps({"ok": True}).encode())
    listen(hop, 9944)   # reachable by any device

SEMANTICS: this is not synchronous HTTP. Inbound is a durable store-and-forward consume; a reply is a
new addressed message that may arrive later. The DX is HTTP-shaped; delivery is delay-tolerant. core
is poll-model, so the endpoint runs a pump thread.
"""
from __future__ import annotations

import threading
import time
from dataclasses import dataclass
from typing import Callable, Optional

from . import _ffi as ffi


def _now_ms() -> int:
    return int(time.time() * 1000)


def _to_bytes(v) -> bytes:
    if isinstance(v, bytes):
        return v
    if isinstance(v, str):
        return v.encode()
    raise TypeError("body/args must be bytes or str")


@dataclass
class HopRequest:
    from_addr: str  # base58, the verified sender identity
    from_bytes: bytes
    service: str
    method: str
    args: bytes

    @property
    def text(self) -> str:
        return self.args.decode()


class HopEndpoint:
    def __init__(self, key: Optional[bytes] = None, tick_ms: int = 50):
        ffi.assert_abi()
        self._node = ffi.node_with_secret(key) if key else ffi.node_new()
        ffi.tick(self._node, _now_ms())
        ffi.publish_prekey(self._node)
        self._handlers: dict[str, Callable] = {}
        self._links: dict[int, Callable[[bytes], None]] = {}
        self._pending: dict[bytes, tuple[threading.Event, dict]] = {}
        self._lock = threading.Lock()
        self._closed = False
        self._thread = threading.Thread(target=self._pump_loop, args=(tick_ms / 1000.0,), daemon=True)
        self._thread.start()

    @property
    def address(self) -> str:
        return ffi.to_b58(ffi.address(self._node))

    @property
    def address_bytes(self) -> bytes:
        return ffi.address(self._node)

    def on(self, service: str, handler: Optional[Callable] = None):
        """Register a receiver for a hops:// service. Usable as a decorator: @hop.on("svc")."""
        if handler is None:
            def deco(fn):
                self.on(service, fn)
                return fn
            return deco
        ffi.subscribe(self._node, service)
        self._handlers[service] = handler
        return self

    def request(self, dst, service: str, method: str, args=b"", timeout: float = 15.0):
        """Call a service on a remote endpoint. Blocks until the response returns (delay-tolerant)."""
        dst_bytes = dst if isinstance(dst, bytes) and len(dst) == 32 else ffi.from_b58(dst)
        req_id = ffi.send_service_request(self._node, dst_bytes, service, method, _to_bytes(args))
        ev, holder = threading.Event(), {}
        with self._lock:
            self._pending[req_id] = (ev, holder)
        if not ev.wait(timeout):
            with self._lock:
                self._pending.pop(req_id, None)
            raise TimeoutError(f"hops://{service}/{method} timed out after {timeout}s")
        return holder["status"], holder["body"]

    # ---- bearer seam (used by tcp_bearer) ----
    def _register_link(self, link: int, role: str, send_fn: Callable[[bytes], None]) -> None:
        self._links[link] = send_fn
        ffi.connected(self._node, link, role == "dialer")

    def _deliver(self, link: int, data: bytes) -> None:
        ffi.received(self._node, link, data)

    def _link_down(self, link: int) -> None:
        self._links.pop(link, None)
        ffi.disconnected(self._node, link)

    def _pump_loop(self, dt: float) -> None:
        while not self._closed:
            try:
                self._pump()
            except Exception:  # never let the pump thread die silently
                import traceback

                traceback.print_exc()
            time.sleep(dt)

    def _pump(self) -> None:
        ffi.tick(self._node, _now_ms())
        for link, data in ffi.drain_outgoing(self._node):
            fn = self._links.get(link)
            if fn:
                fn(data)
        for frm, rid, service, method, args in ffi.take_service_requests(self._node):
            handler = self._handlers.get(service)
            if handler:
                req = HopRequest(ffi.to_b58(frm), frm, service, method, args)
                reply = _Reply(self._node, frm, rid)
                handler(req, reply)
        for _frm, for_id, status, body in ffi.take_service_responses(self._node):
            with self._lock:
                p = self._pending.pop(for_id, None)
            if p:
                ev, holder = p
                holder["status"], holder["body"] = status, body
                ev.set()

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        self._thread.join(timeout=1.0)
        ffi.node_free(self._node)


class _Reply:
    def __init__(self, node, to: bytes, for_request_id: bytes):
        self._node, self._to, self._for = node, to, for_request_id
        self._sent = False

    def __call__(self, status: int, body=b"") -> bool:
        if self._sent:
            raise RuntimeError("reply already sent")
        self._sent = True
        return ffi.send_service_response(self._node, self._to, self._for, status, _to_bytes(body))
