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
        self._closers: list[Callable[[], None]] = []
        # Reentrant: the pump never holds the lock across a handler, but a reply issued from a handler
        # (or a handler that calls back into the endpoint) still re-enters cleanly.
        self._lock = threading.RLock()
        self._closed = False
        self._thread = threading.Thread(target=self._pump_loop, args=(tick_ms / 1000.0,), daemon=True)
        self._thread.start()

    def _with_node(self, fn):
        """Run a libhop call on the node under the lock, unless closed (the node may already be freed, so
        we must not touch it). Returns fn's result, or None when closed."""
        with self._lock:
            if self._closed:
                return None
            return fn(self._node)

    def _register_closer(self, fn: Callable[[], None]) -> None:
        """Record a bearer teardown hook (e.g. a listening socket); close() runs it before freeing the
        node. If already closed, it fires immediately."""
        with self._lock:
            if not self._closed:
                self._closers.append(fn)
                return
        fn()

    @property
    def address(self) -> str:
        return ffi.to_b58(self._with_node(ffi.address))

    @property
    def address_bytes(self) -> bytes:
        return self._with_node(ffi.address)

    def on(self, service: str, handler: Optional[Callable] = None):
        """Register a receiver for a hops:// service. Usable as a decorator: @hop.on("svc")."""
        if handler is None:
            def deco(fn):
                self.on(service, fn)
                return fn
            return deco
        self._with_node(lambda n: ffi.subscribe(n, service))
        self._handlers[service] = handler
        return self

    def request(self, dst, service: str, method: str, args=b"", timeout: float = 15.0):
        """Call a service on a remote endpoint. Blocks until the response returns (delay-tolerant)."""
        dst_bytes = dst if isinstance(dst, bytes) and len(dst) == 32 else ffi.from_b58(dst)
        ev, holder = threading.Event(), {}
        # Send + register the waiter atomically so the pump can't deliver the response before _pending
        # knows to route it, and so a concurrent close() cannot free the node mid-send.
        with self._lock:
            if self._closed:
                raise RuntimeError("endpoint is closed")
            req_id = ffi.send_service_request(self._node, dst_bytes, service, method, _to_bytes(args))
            self._pending[req_id] = (ev, holder)
        if not ev.wait(timeout):
            with self._lock:
                self._pending.pop(req_id, None)
            raise TimeoutError(f"hops://{service}/{method} timed out after {timeout}s")
        return holder["status"], holder["body"]

    def sign_reach(self, endpoint: str, ttl_secs: int = 3600) -> bytes:
        """Sign a self-certifying reachability record for this endpoint's address bound to `endpoint`."""
        return self._with_node(lambda n: ffi.sign_reach(n, endpoint, ttl_secs))

    def attach(self, host, port, ssl_context, public_url, ttl_secs=3600):
        """Wire this endpoint into a threaded HTTPS server IN ONE CALL: the WSS bearer at /_hop and the
        /.well-known/hop discovery responder. Returns the listen socket. `public_url` is where senders
        reach it, e.g. "wss://myaddress.com/_hop". (Python has no standard existing-server object, so
        attach starts the server; run it on 443 or behind a reverse proxy.)"""
        from .wss_bearer import serve

        return serve(self, host, port, ssl_context, public_url, ttl_secs)

    def dial_by_name(self, base_url, insecure_tls: bool = False):
        """Resolve a base HTTPS URL to a verified endpoint, dial its WSS, and return the reachable
        address (then use request()). Set insecure_tls only for a dev/self-signed cert."""
        from .discovery import _ssl_context, resolve
        from .wss_bearer import dial

        info = resolve(base_url, insecure_tls=insecure_tls)
        dial(self, info["wss_url"], _ssl_context(insecure_tls))
        return info["address"]

    # ---- bearer seam (used by tcp_bearer) ----
    def _register_link(self, link: int, role: str, send_fn: Callable[[bytes], None]) -> None:
        with self._lock:
            if self._closed:
                return
            self._links[link] = send_fn
            ffi.connected(self._node, link, role == "dialer")

    def _deliver(self, link: int, data: bytes) -> None:
        with self._lock:
            if self._closed:
                return
            ffi.received(self._node, link, data)

    def _link_down(self, link: int) -> None:
        with self._lock:
            if self._closed:
                return
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
        # Collect under the lock (fast native calls); run bearer sends + handlers OUTSIDE it, so a slow
        # handler never blocks close() or another link, and a reply re-enters via its own _with_node.
        with self._lock:
            if self._closed:
                return
            ffi.tick(self._node, _now_ms())
            outgoing = ffi.drain_outgoing(self._node)
        for link, data in outgoing:
            fn = self._links.get(link)
            if fn:
                fn(data)
        with self._lock:
            if self._closed:
                return
            reqs = ffi.take_service_requests(self._node)
        for frm, rid, service, method, args in reqs:
            handler = self._handlers.get(service)
            if handler:
                req = HopRequest(ffi.to_b58(frm), frm, service, method, args)
                reply = _Reply(self, frm, rid)
                handler(req, reply)
        with self._lock:
            if self._closed:
                return
            resps = ffi.take_service_responses(self._node)
        for _frm, for_id, status, body in resps:
            with self._lock:
                p = self._pending.pop(for_id, None)
            if p:
                ev, holder = p
                holder["status"], holder["body"] = status, body
                ev.set()

    def close(self) -> None:
        with self._lock:
            if self._closed:
                return
            self._closed = True
            closers, self._closers = self._closers, []
        for c in closers:  # unblock bearer accept/recv threads so they exit
            try:
                c()
            except Exception:
                pass
        self._thread.join(timeout=1.0)
        # Free under the lock: a late bearer-thread seam call now short-circuits on _closed instead of
        # touching a freed node, and the join timeout can no longer let the pump race the free.
        with self._lock:
            ffi.node_free(self._node)


class _Reply:
    def __init__(self, endpoint, to: bytes, for_request_id: bytes):
        self._ep, self._to, self._for = endpoint, to, for_request_id
        self._sent = False

    def __call__(self, status: int, body=b"") -> bool:
        if self._sent:
            raise RuntimeError("reply already sent")
        self._sent = True
        return bool(
            self._ep._with_node(lambda n: ffi.send_service_response(n, self._to, self._for, status, _to_bytes(body)))
        )
