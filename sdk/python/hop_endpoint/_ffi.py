"""Raw ctypes bindings to libhop (the C ABI, sdk/hop.h). Thin and one-to-one; ergonomics live in
endpoint.py. No third-party deps: ctypes is in the stdlib.

libhop is resolved from HOP_LIBDIR (same env the Kotlin SDK uses) or the in-repo build.
"""
from __future__ import annotations

import ctypes as C
import os
import sys
from ctypes import CFUNCTYPE, POINTER, c_char_p, c_size_t, c_ssize_t, c_uint8, c_uint16, c_uint32, c_uint64, c_void_p, c_bool
from pathlib import Path

_EXT = {"darwin": "dylib", "win32": "dll"}.get(sys.platform, "so")
_ABI_EXPECTED = 7


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
SVCREQ_SINK = CFUNCTYPE(c_bool, c_void_p, POINTER(c_uint8), POINTER(c_uint8), c_char_p, c_char_p, POINTER(c_uint8), c_size_t)
SVCRESP_SINK = CFUNCTYPE(c_bool, c_void_p, POINTER(c_uint8), POINTER(c_uint8), c_uint16, POINTER(c_uint8), c_size_t)
REACH_SIGN_SINK = CFUNCTYPE(None, c_void_p, POINTER(c_uint8), c_size_t)
REACH_VERIFY_SINK = CFUNCTYPE(None, c_void_p, POINTER(c_uint8), c_char_p, c_uint64, c_uint32)
# §32 hps:// sinks. ADDR32_SINK is the one-32-byte-pointer shape three calls share: a requester
# (hop_hps_pending), a member (hop_hps_members) and a rekey bundle id (hop_hps_rekey).
HPSMSG_SINK = CFUNCTYPE(c_bool, c_void_p, POINTER(c_uint8), c_char_p, POINTER(c_uint8), POINTER(c_uint8), c_size_t)
HPSINVITE_SINK = CFUNCTYPE(None, c_void_p, POINTER(c_uint8), c_char_p, c_uint32)
ADDR32_SINK = CFUNCTYPE(None, c_void_p, POINTER(c_uint8))
HPSTOPIC_SINK = CFUNCTYPE(None, c_void_p, POINTER(c_uint8), c_char_p, c_uint32, c_bool, c_uint32)
HPSINFO_SINK = CFUNCTYPE(None, c_void_p, POINTER(c_uint8), c_char_p, c_uint32, c_char_p, c_char_p, c_uint32)

# ---- signatures (restype MUST be set, else ctypes truncates 64-bit pointers) ----
_lib.hop_abi_version.restype = c_uint32
_lib.hop_node_new.restype = c_void_p
_lib.hop_node_with_secret.argtypes = [c_char_p, c_size_t]
_lib.hop_node_with_secret.restype = c_void_p
_lib.hop_node_is_encrypted.argtypes = [c_void_p]
_lib.hop_node_is_encrypted.restype = c_bool
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
_lib.hop_accept_inbox.argtypes = [c_void_p, c_char_p]
_lib.hop_accept_inbox.restype = c_bool
_lib.hop_send_service_request.argtypes = [c_void_p, c_char_p, c_char_p, c_char_p, c_char_p, c_size_t, c_char_p]
_lib.hop_send_service_request.restype = c_bool
_lib.hop_send_service_response.argtypes = [c_void_p, c_char_p, c_char_p, c_uint16, c_char_p, c_size_t]
_lib.hop_send_service_response.restype = c_bool
_lib.hop_poll_service_requests.argtypes = [c_void_p, SVCREQ_SINK, c_void_p]
_lib.hop_poll_service_responses.argtypes = [c_void_p, SVCRESP_SINK, c_void_p]
_lib.hop_accept_service_response.argtypes = [c_void_p, c_char_p]
_lib.hop_accept_service_response.restype = c_bool
_lib.hop_accept_service_request.argtypes = [c_void_p, c_char_p]
_lib.hop_accept_service_request.restype = c_bool
_lib.hop_reject_service_request.argtypes = [c_void_p, c_char_p]
_lib.hop_reject_service_request.restype = c_bool
_lib.hop_address_to_base58.argtypes = [c_char_p, c_char_p, c_size_t]
_lib.hop_address_to_base58.restype = c_size_t
_lib.hop_address_from_base58.argtypes = [c_char_p, c_char_p]
_lib.hop_address_from_base58.restype = c_bool
_lib.hop_sign_reach_record.argtypes = [c_void_p, c_char_p, c_uint32, REACH_SIGN_SINK, c_void_p]
_lib.hop_verify_reach_record.argtypes = [c_char_p, c_size_t, c_uint64, REACH_VERIFY_SINK, c_void_p]
_lib.hop_verify_reach_record.restype = c_bool
# §19 relay pool. PLAT-003: the four calls the v4 -> v5 ABI bump this wrapper pins was taken for,
# which no C-ABI wrapper bound, so a host on the published SDKs could not fail over off a dead relay.
_lib.hop_relay_add.argtypes = [c_void_p, c_char_p, c_bool]
_lib.hop_relay_add.restype = c_bool
_lib.hop_relay_next.argtypes = [c_void_p, c_char_p, c_size_t]
_lib.hop_relay_next.restype = c_size_t
_lib.hop_relay_report.argtypes = [c_void_p, c_char_p, c_bool]
_lib.hop_relay_pool_size.argtypes = [c_void_p, POINTER(c_size_t)]
_lib.hop_relay_pool_size.restype = c_size_t
# Endpoint clustering (DESIGN.md §40).
_lib.hop_cluster_join.argtypes = [c_void_p, c_char_p]
_lib.hop_cluster_join_passphrase.argtypes = [c_void_p, c_char_p, c_size_t]
_lib.hop_cluster_members.argtypes = [c_void_p]
_lib.hop_cluster_members.restype = c_uint32
_lib.hop_cluster_set_quorum.argtypes = [c_void_p, c_uint32]
# §32 hps:// pub/sub (services and channels, i.e. group chat). PLAT-005: the eighteen calls the
# v5 -> v6 bump was taken for. The C ABI had no hps exports at all, so no wrapper sitting on it could
# reach a channel even though the protocol has shipped in the two native UniFFI drivers for as long
# as it has existed. Declaring them here is load-bearing rather than decorative: each attribute
# lookup resolves the symbol out of libhop at import, so pairing this wrapper with a library that
# does not export the v6 surface fails at load instead of at the first channel a host tries to open.
#
# A publication is NOT one-to-one fan-out and NOT a multicast bundle. It is a single
# content-key-encrypted, per-writer-signed publication, flooded once, which is why most of this
# surface is about a topic's key handoff (subscribe, invite, approve, rekey) rather than about bytes.
#
# Signature details worth keeping straight, each of which exists to stop a caller conflating two
# outcomes:
#   register  writes the service key's length through its own out-param, so a channel (zero-length
#             key, since its writers sign with their own identity) is distinguishable from a
#             failure; the bool return is what says whether registration happened.
#   leave     writes out_has_id, because leaving a topic we HOST sends no bundle: a success with no
#             id, not a failure.
#   rekey     takes a COUNT of 32-byte addresses packed back to back, not a byte length.
#   kind/access/visibility cross as plain uint32 discriminants and are passed through untouched. An
#             out-of-range value makes the call FAIL; it is never coerced or defaulted here, because
#             reading a garbage int as Open would hand a topic's keys to anyone who asks.
_lib.hop_hps_register.argtypes = [c_void_p, c_char_p, c_uint32, c_uint32, c_uint32, c_char_p, c_size_t, POINTER(c_size_t)]
_lib.hop_hps_register.restype = c_bool
_lib.hop_hps_subscribe.argtypes = [c_void_p, c_char_p, c_char_p, c_char_p]
_lib.hop_hps_subscribe.restype = c_bool
_lib.hop_hps_publish.argtypes = [c_void_p, c_char_p, c_char_p, c_size_t, c_char_p]
_lib.hop_hps_publish.restype = c_bool
_lib.hop_poll_hps_messages.argtypes = [c_void_p, HPSMSG_SINK, c_void_p]
_lib.hop_accept_hps_message.argtypes = [c_void_p, c_char_p]
_lib.hop_accept_hps_message.restype = c_bool
_lib.hop_hps_invite.argtypes = [c_void_p, c_char_p, c_char_p, c_char_p]
_lib.hop_hps_invite.restype = c_bool
_lib.hop_hps_accept_invite.argtypes = [c_void_p, c_char_p, c_char_p, c_char_p]
_lib.hop_hps_accept_invite.restype = c_bool
_lib.hop_hps_decline_invite.argtypes = [c_void_p, c_char_p, c_char_p]
_lib.hop_hps_decline_invite.restype = c_bool
_lib.hop_poll_hps_invites.argtypes = [c_void_p, HPSINVITE_SINK, c_void_p]
_lib.hop_hps_leave.argtypes = [c_void_p, c_char_p, c_char_p, POINTER(c_bool)]
_lib.hop_hps_leave.restype = c_bool
_lib.hop_hps_pending.argtypes = [c_void_p, c_char_p, ADDR32_SINK, c_void_p]
_lib.hop_hps_pending.restype = c_size_t
_lib.hop_hps_approve.argtypes = [c_void_p, c_char_p, c_char_p, c_char_p]
_lib.hop_hps_approve.restype = c_bool
_lib.hop_hps_deny.argtypes = [c_void_p, c_char_p, c_char_p]
_lib.hop_hps_deny.restype = c_bool
_lib.hop_hps_rekey.argtypes = [c_void_p, c_char_p, c_char_p, c_char_p, c_size_t, ADDR32_SINK, c_void_p]
_lib.hop_hps_rekey.restype = c_ssize_t
_lib.hop_hps_reach.argtypes = [c_void_p, c_char_p]
_lib.hop_hps_reach.restype = c_uint32
_lib.hop_hps_members.argtypes = [c_void_p, c_char_p, ADDR32_SINK, c_void_p]
_lib.hop_hps_members.restype = c_size_t
_lib.hop_hps_my_topics.argtypes = [c_void_p, HPSTOPIC_SINK, c_void_p]
_lib.hop_hps_my_topics.restype = c_size_t
_lib.hop_hps_browse.argtypes = [c_void_p, HPSINFO_SINK, c_void_p]
_lib.hop_hps_browse.restype = c_size_t


def assert_abi() -> None:
    got = _lib.hop_abi_version()
    if got != _ABI_EXPECTED:
        raise RuntimeError(f"libhop ABI mismatch: header expects {_ABI_EXPECTED}, library reports {got}")


def _require32(value: bytes, name: str) -> bytes:
    if len(value) != 32:
        raise ValueError(f"{name} must be exactly 32 bytes, got {len(value)}")
    return value


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


def accept_inbox(node, inbox_id: bytes) -> bool:
    return bool(_lib.hop_accept_inbox(node, _require32(inbox_id, "inbox id")))


def drain_outgoing(node) -> list[tuple[int, bytes]]:
    out: list[tuple[int, bytes]] = []

    @DRAIN_SINK
    def sink(_ctx, link, ptr, length):
        out.append((int(link), C.string_at(ptr, length) if length else b""))

    _lib.hop_drain_outgoing(node, sink, None)
    return out


def send_service_request(node, dst: bytes, service: str, method: str, args: bytes) -> bytes:
    out = C.create_string_buffer(32)
    ok = _lib.hop_send_service_request(
        node, _require32(dst, "destination"), service.encode(), method.encode(), args, len(args), out
    )
    if not ok:
        raise RuntimeError("hop_send_service_request failed")
    return out.raw[:32]


def send_service_response(node, to: bytes, for_request_id: bytes, status: int, body: bytes) -> bool:
    return bool(
        _lib.hop_send_service_response(
            node,
            _require32(to, "response destination"),
            _require32(for_request_id, "request id"),
            status,
            body,
            len(body),
        )
    )


def accept_service_response(node, request_id: bytes) -> bool:
    return bool(_lib.hop_accept_service_response(node, _require32(request_id, "request id")))


def is_encrypted(node) -> bool:
    return bool(_lib.hop_node_is_encrypted(node))


def accept_service_request(node, request_id: bytes) -> bool:
    return bool(_lib.hop_accept_service_request(node, _require32(request_id, "request id")))


def reject_service_request(node, request_id: bytes) -> bool:
    return bool(_lib.hop_reject_service_request(node, _require32(request_id, "request id")))

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
        return True

    _lib.hop_poll_service_requests(node, sink, None)
    return out


def take_service_responses(node) -> list[tuple[bytes, bytes, int, bytes]]:
    out: list[tuple[bytes, bytes, int, bytes]] = []

    @SVCRESP_SINK
    def sink(_ctx, frm, for_id, status, body, body_len):
        out.append((C.string_at(frm, 32), C.string_at(for_id, 32), int(status), C.string_at(body, body_len) if body_len else b""))
        return False

    _lib.hop_poll_service_responses(node, sink, None)
    return out


def to_b58(addr32: bytes) -> str:
    out = C.create_string_buffer(64)
    n = _lib.hop_address_to_base58(_require32(addr32, "address"), out, 64)
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


def relay_add(node, url: str, configured: bool = True) -> bool:
    """Offer a relay endpoint to the §19 pool; True if it is now pooled."""
    return bool(_lib.hop_relay_add(node, url.encode(), configured))


def relay_next(node) -> str | None:
    """The relay to dial right now, or None when there is nothing dialable.

    None with a non-zero ``relay_pool()`` total is the degraded "every candidate is backed off"
    state (wait and retry, this is not offline); None with a zero total is an empty pool. The 2 KiB
    buffer is far past any real endpoint URL; the C call writes nothing and returns 0 if a URL would
    not fit, which surfaces here as "nothing to dial".
    """
    out = C.create_string_buffer(2048)
    n = int(_lib.hop_relay_next(node, out, len(out)))
    return out.raw[:n].decode() if n else None


def relay_report(node, url: str, ok: bool) -> None:
    """Feed a dial outcome back to the pool so it can score the endpoint."""
    _lib.hop_relay_report(node, url.encode(), ok)


def relay_pool(node) -> tuple[int, int]:
    """(total pooled endpoints, how many are dialable right now)."""
    available = c_size_t(0)
    total = int(_lib.hop_relay_pool_size(node, C.byref(available)))
    return total, int(available.value)


def cluster_join(node, secret: bytes) -> None:
    _lib.hop_cluster_join(node, _require32(secret, "cluster secret"))


def hps_rekey(node, path: str, new_path: str = "", remove: list[bytes] | None = None) -> list[bytes]:
    remove_list = remove or []
    packed = bytearray()
    for addr in remove_list:
        packed.extend(_require32(addr, "remove address"))
    out: list[bytes] = []

    @ADDR32_SINK
    def sink(_ctx, id_ptr):
        out.append(C.string_at(id_ptr, 32))

    res = _lib.hop_hps_rekey(
        node,
        path.encode(),
        new_path.encode() if new_path else None,
        bytes(packed) if packed else None,
        len(remove_list),
        sink,
        None,
    )
    if res < 0:
        raise RuntimeError(f'hop_hps_rekey("{path}") failed')
    return out


def cluster_join_passphrase(node, passphrase: bytes) -> None:
    _lib.hop_cluster_join_passphrase(node, passphrase, len(passphrase))


def cluster_members(node) -> int:
    return int(_lib.hop_cluster_members(node))


def cluster_set_quorum(node, min_live_members: int) -> None:
    _lib.hop_cluster_set_quorum(node, min_live_members)
