"""Raw ctypes bindings to libhop (the C ABI, sdk/hop.h). Thin and one-to-one; ergonomics live in
endpoint.py. No third-party deps: ctypes is in the stdlib.

libhop is resolved from HOP_LIBDIR (same env the Kotlin SDK uses) or the in-repo build.
"""
from __future__ import annotations

import ctypes as C
import os
import sys
from ctypes import CFUNCTYPE, POINTER, c_char_p, c_size_t, c_uint8, c_uint16, c_uint32, c_uint64, c_void_p, c_bool
from pathlib import Path

_EXT = {"darwin": "dylib", "win32": "dll"}.get(sys.platform, "so")
_ABI_EXPECTED = 3


def _resolve_lib() -> str:
    repo = Path(__file__).resolve().parents[3]  # sdk/python/hop_endpoint -> repo root
    candidates = []
    if os.environ.get("HOP_LIBDIR"):
        candidates.append(Path(os.environ["HOP_LIBDIR"]) / f"libhop.{_EXT}")
    candidates += [repo / "target" / p / f"libhop.{_EXT}" for p in ("debug", "release")]
    for c in candidates:
        if c.exists():
            return str(c)
    raise OSError(
        "libhop." + _EXT + " not found. Build it with `cargo build -p hop` or set HOP_LIBDIR.\n"
        "Looked in:\n  " + "\n  ".join(str(c) for c in candidates)
    )


_lib = C.CDLL(_resolve_lib())

# ---- callback prototypes (invoked synchronously during the poll/drain call) ----
DRAIN_SINK = CFUNCTYPE(None, c_void_p, c_uint64, POINTER(c_uint8), c_size_t)
SVCREQ_SINK = CFUNCTYPE(None, c_void_p, POINTER(c_uint8), POINTER(c_uint8), c_char_p, c_char_p, POINTER(c_uint8), c_size_t)
SVCRESP_SINK = CFUNCTYPE(None, c_void_p, POINTER(c_uint8), POINTER(c_uint8), c_uint16, POINTER(c_uint8), c_size_t)
REACH_SIGN_SINK = CFUNCTYPE(None, c_void_p, POINTER(c_uint8), c_size_t)
REACH_VERIFY_SINK = CFUNCTYPE(None, c_void_p, POINTER(c_uint8), c_char_p, c_uint64, c_uint32)

# ---- signatures (restype MUST be set, else ctypes truncates 64-bit pointers) ----
_lib.hop_abi_version.restype = c_uint32
_lib.hop_node_new.restype = c_void_p
_lib.hop_node_with_secret.argtypes = [c_char_p, c_size_t]
_lib.hop_node_with_secret.restype = c_void_p
_lib.hop_node_free.argtypes = [c_void_p]
_lib.hop_node_address.argtypes = [c_void_p, c_char_p]
_lib.hop_node_address.restype = c_bool
_lib.hop_node_tick.argtypes = [c_void_p, c_uint64]
_lib.hop_link_up.argtypes = [c_void_p, c_uint64, c_uint32]
_lib.hop_bytes_received.argtypes = [c_void_p, c_uint64, c_char_p, c_size_t]
_lib.hop_link_down.argtypes = [c_void_p, c_uint64]
_lib.hop_drain_outgoing.argtypes = [c_void_p, DRAIN_SINK, c_void_p]
_lib.hop_subscribe.argtypes = [c_void_p, c_char_p]
_lib.hop_publish_prekey.argtypes = [c_void_p]
_lib.hop_publish_prekey.restype = c_bool
_lib.hop_send_service_request.argtypes = [c_void_p, c_char_p, c_char_p, c_char_p, c_char_p, c_size_t, c_char_p]
_lib.hop_send_service_request.restype = c_bool
_lib.hop_send_service_response.argtypes = [c_void_p, c_char_p, c_char_p, c_uint16, c_char_p, c_size_t]
_lib.hop_send_service_response.restype = c_bool
_lib.hop_poll_service_requests.argtypes = [c_void_p, SVCREQ_SINK, c_void_p]
_lib.hop_poll_service_responses.argtypes = [c_void_p, SVCRESP_SINK, c_void_p]
_lib.hop_address_to_base58.argtypes = [c_char_p, c_char_p, c_size_t]
_lib.hop_address_to_base58.restype = c_size_t
_lib.hop_address_from_base58.argtypes = [c_char_p, c_char_p]
_lib.hop_address_from_base58.restype = c_bool
_lib.hop_sign_reach_record.argtypes = [c_void_p, c_char_p, c_uint32, REACH_SIGN_SINK, c_void_p]
_lib.hop_verify_reach_record.argtypes = [c_char_p, c_size_t, c_uint64, REACH_VERIFY_SINK, c_void_p]
_lib.hop_verify_reach_record.restype = c_bool
# Endpoint clustering (DESIGN.md §40).
_lib.hop_cluster_join.argtypes = [c_void_p, c_char_p]
_lib.hop_cluster_join_passphrase.argtypes = [c_void_p, c_char_p, c_size_t]
_lib.hop_cluster_members.argtypes = [c_void_p]
_lib.hop_cluster_members.restype = c_uint32


def assert_abi() -> None:
    got = _lib.hop_abi_version()
    if got != _ABI_EXPECTED:
        raise RuntimeError(f"libhop ABI mismatch: header expects {_ABI_EXPECTED}, library reports {got}")


# ---- thin wrappers ----
def node_new() -> c_void_p:
    return c_void_p(_lib.hop_node_new())


def node_with_secret(secret: bytes) -> c_void_p:
    return c_void_p(_lib.hop_node_with_secret(secret, len(secret)))


def node_free(node) -> None:
    _lib.hop_node_free(node)


def address(node) -> bytes:
    out = C.create_string_buffer(32)
    _lib.hop_node_address(node, out)
    return out.raw[:32]


def tick(node, now_ms: int) -> None:
    _lib.hop_node_tick(node, now_ms)


def connected(node, link: int, initiator: bool) -> None:
    _lib.hop_link_up(node, link, 0 if initiator else 1)


def disconnected(node, link: int) -> None:
    _lib.hop_link_down(node, link)


def received(node, link: int, data: bytes) -> None:
    _lib.hop_bytes_received(node, link, data, len(data))


def subscribe(node, topic: str) -> None:
    _lib.hop_subscribe(node, topic.encode())


def publish_prekey(node) -> bool:
    return bool(_lib.hop_publish_prekey(node))


def drain_outgoing(node) -> list[tuple[int, bytes]]:
    out: list[tuple[int, bytes]] = []

    @DRAIN_SINK
    def sink(_ctx, link, ptr, length):
        out.append((int(link), C.string_at(ptr, length) if length else b""))

    _lib.hop_drain_outgoing(node, sink, None)
    return out


def send_service_request(node, dst: bytes, service: str, method: str, args: bytes) -> bytes:
    out = C.create_string_buffer(32)
    ok = _lib.hop_send_service_request(node, dst, service.encode(), method.encode(), args, len(args), out)
    if not ok:
        raise RuntimeError("hop_send_service_request failed")
    return out.raw[:32]


def send_service_response(node, to: bytes, for_request_id: bytes, status: int, body: bytes) -> bool:
    return bool(_lib.hop_send_service_response(node, to, for_request_id, status, body, len(body)))


def take_service_requests(node) -> list[tuple[bytes, bytes, str, str, bytes]]:
    out: list[tuple[bytes, bytes, str, str, bytes]] = []

    @SVCREQ_SINK
    def sink(_ctx, frm, rid, service, method, args, arglen):
        out.append(
            (
                C.string_at(frm, 32),
                C.string_at(rid, 32),
                service.decode(),
                method.decode(),
                C.string_at(args, arglen) if arglen else b"",
            )
        )

    _lib.hop_poll_service_requests(node, sink, None)
    return out


def take_service_responses(node) -> list[tuple[bytes, bytes, int, bytes]]:
    out: list[tuple[bytes, bytes, int, bytes]] = []

    @SVCRESP_SINK
    def sink(_ctx, frm, for_id, status, body, body_len):
        out.append((C.string_at(frm, 32), C.string_at(for_id, 32), int(status), C.string_at(body, body_len) if body_len else b""))

    _lib.hop_poll_service_responses(node, sink, None)
    return out


def to_b58(addr32: bytes) -> str:
    out = C.create_string_buffer(64)
    n = _lib.hop_address_to_base58(addr32, out, 64)
    return out.raw[:n].decode()


def from_b58(text: str) -> bytes:
    out = C.create_string_buffer(32)
    if not _lib.hop_address_from_base58(text.encode(), out):
        raise ValueError(f"not a valid Hop address: {text}")
    return out.raw[:32]


def sign_reach(node, endpoint: str, ttl_secs: int) -> bytes:
    """Sign a self-certifying reachability record for this node's address -> record bytes."""
    out: list[bytes] = []

    @REACH_SIGN_SINK
    def sink(_ctx, ptr, length):
        out.append(C.string_at(ptr, length) if length else b"")

    _lib.hop_sign_reach_record(node, endpoint.encode(), ttl_secs, sink, None)
    return out[0] if out else b""


def verify_reach(record: bytes, now_secs: int) -> dict | None:
    """Verify a reach record. Returns {address, address_b58, endpoint, issued_at, ttl_secs} or None."""
    info: dict = {}

    @REACH_VERIFY_SINK
    def sink(_ctx, addr_ptr, endpoint, issued_at, ttl_secs):
        a = C.string_at(addr_ptr, 32)
        info.update(address=a, address_b58=to_b58(a), endpoint=endpoint.decode(), issued_at=int(issued_at), ttl_secs=int(ttl_secs))

    ok = _lib.hop_verify_reach_record(record, len(record), now_secs, sink, None)
    return info if ok and info else None


def cluster_join(node, secret: bytes) -> None:
    _lib.hop_cluster_join(node, secret)


def cluster_join_passphrase(node, passphrase: bytes) -> None:
    _lib.hop_cluster_join_passphrase(node, passphrase, len(passphrase))


def cluster_members(node) -> int:
    return int(_lib.hop_cluster_members(node))
