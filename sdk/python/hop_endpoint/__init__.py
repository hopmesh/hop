"""Receive Hop messages in Python: an embeddable endpoint over the libhop C ABI (via ctypes)."""
from .endpoint import HopEndpoint, HopRequest
from .tcp_bearer import dial, listen

__all__ = ["HopEndpoint", "HopRequest", "listen", "dial", "connect_in_process"]


def connect_in_process(a: HopEndpoint, b: HopEndpoint, la: int = 11, lb: int = 22):
    """Wire two endpoints directly (in-process bearer). Proves the ergonomics end to end without
    sockets; use listen/dial for a real, reachable endpoint."""
    a._register_link(la, "dialer", lambda buf: b._deliver(lb, buf))
    b._register_link(lb, "acceptor", lambda buf: a._deliver(la, buf))
