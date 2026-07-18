"""The WSS Internet bearer for a Python endpoint, in pure stdlib (no third-party deps). A minimal
RFC 6455 WebSocket: the Upgrade handshake + binary framing, over the threaded socket model the TCP
bearer already uses. core does the Noise handshake and all crypto over the frame payloads; one drained
packet is one binary WS message. The server also answers GET /.well-known/hop on the same port, so
attach() wires both in one call."""
from __future__ import annotations

import base64
import hashlib
import os
import queue
import socket
import struct
import threading
import time
from itertools import count
from urllib.parse import urlparse

from .discovery import well_known_body

_WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
_link_seq = count(60000)
MAX_MESSAGE_BYTES = 1 << 20
MAX_FRAME_BYTES = MAX_MESSAGE_BYTES
MAX_HEADER_BYTES = 16 << 10
MAX_PENDING_CONNECTIONS = 64
HANDSHAKE_WORKERS = 4
HANDSHAKE_TIMEOUT_S = 5.0
READ_TIMEOUT_S = 15.0


def _accept_key(key: str) -> str:
    return base64.b64encode(hashlib.sha1((key + _WS_GUID).encode()).digest()).decode()


class _Conn:
    """A socket with a read buffer, so a handshake read never over-consumes into frame bytes."""

    def __init__(self, sock, initial: bytes = b""):
        self.sock = sock
        self.buf = bytearray(initial)
        self.deadline = None

    def begin_read(self) -> None:
        self.deadline = time.monotonic() + READ_TIMEOUT_S

    def recv_exact(self, n: int) -> bytes:
        while len(self.buf) < n:
            if self.deadline is not None:
                remaining = self.deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("WebSocket read deadline exceeded")
                self.sock.settimeout(remaining)
            chunk = self.sock.recv(min(65536, n - len(self.buf)))
            if not chunk:
                raise ConnectionError("closed")
            self.buf.extend(chunk)
        out = bytes(self.buf[:n])
        del self.buf[:n]
        return out


def _encode_frame(payload: bytes, mask: bool) -> bytes:
    if len(payload) > MAX_MESSAGE_BYTES:
        raise ValueError("WebSocket message exceeds 1 MiB")
    header = bytearray([0x82])  # FIN + binary opcode
    n = len(payload)
    mb = 0x80 if mask else 0
    if n < 126:
        header.append(mb | n)
    elif n < 65536:
        header.append(mb | 126)
        header += struct.pack(">H", n)
    else:
        header.append(mb | 127)
        header += struct.pack(">Q", n)
    if mask:
        mk = os.urandom(4)
        header += mk
        payload = bytes(b ^ mk[i % 4] for i, b in enumerate(payload))
    return bytes(header) + payload


def _read_frame_part(c: _Conn, remaining: int = MAX_MESSAGE_BYTES) -> tuple[bool, int, bytes]:
    b0, b1 = c.recv_exact(2)
    if b0 & 0x70:
        raise ConnectionError("WebSocket extensions are not supported")
    final = bool(b0 & 0x80)
    opcode = b0 & 0x0F
    masked = b1 & 0x80
    n = b1 & 0x7F
    if n == 126:
        n = struct.unpack(">H", c.recv_exact(2))[0]
    elif n == 127:
        n = struct.unpack(">Q", c.recv_exact(8))[0]
    if n > remaining or n > MAX_MESSAGE_BYTES:
        raise ConnectionError("WebSocket message exceeds 1 MiB")
    if opcode >= 0x8 and (not final or n > 125):
        raise ConnectionError("invalid WebSocket control frame")
    mk = c.recv_exact(4) if masked else None
    payload = c.recv_exact(n)
    if mk:
        payload = bytes(b ^ mk[i % 4] for i, b in enumerate(payload))
    return final, opcode, payload


def _read_frame(c: _Conn) -> tuple[int, bytes]:
    """Read one wire frame. Kept as a focused test seam; links use cumulative _read_message."""
    _final, opcode, payload = _read_frame_part(c)
    return opcode, payload


def _read_message(c: _Conn) -> tuple[int, bytes]:
    if hasattr(c, "begin_read"):
        c.begin_read()
    final, opcode, payload = _read_frame_part(c)
    if opcode >= 0x8:
        return opcode, payload
    if opcode != 0x2:
        raise ConnectionError("expected a binary WebSocket message")
    if final:
        return opcode, payload

    chunks = [payload]
    total = len(payload)
    while not final:
        final, continuation, payload = _read_frame_part(c, MAX_MESSAGE_BYTES - total)
        if continuation != 0x0:
            raise ConnectionError("expected a WebSocket continuation frame")
        total += len(payload)
        chunks.append(payload)
    return opcode, b"".join(chunks)


def _safe_send(sock, data: bytes) -> None:
    try:
        sock.sendall(data)
    except OSError:
        pass


def _run_link(endpoint, c: _Conn, role: str, mask: bool) -> None:
    link = next(_link_seq)
    endpoint._register_link(link, role, lambda buf: _safe_send(c.sock, _encode_frame(buf, mask)))
    try:
        while True:
            opcode, payload = _read_message(c)
            if opcode == 0x8:  # close
                break
            if opcode == 0x2:
                endpoint._deliver(link, payload)
    except (ConnectionError, OSError, TimeoutError):
        pass
    finally:
        endpoint._link_down(link)
        try:
            c.sock.close()
        except OSError:
            pass


def _read_http_bytes(sock) -> tuple[bytes, bytes]:
    data = bytearray()
    deadline = time.monotonic() + HANDSHAKE_TIMEOUT_S
    while b"\r\n\r\n" not in data:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("HTTP handshake deadline exceeded")
        sock.settimeout(remaining)
        chunk = sock.recv(min(4096, MAX_HEADER_BYTES + 1 - len(data)))
        if not chunk:
            raise ConnectionError("closed")
        data.extend(chunk)
        if len(data) > MAX_HEADER_BYTES:
            raise ConnectionError("HTTP headers exceed 16 KiB")
    head, _, rest = bytes(data).partition(b"\r\n\r\n")
    return head, rest


def _read_http_head(sock) -> tuple[str, str, dict, bytes]:
    head, rest = _read_http_bytes(sock)
    lines = head.decode("latin1").split("\r\n")
    try:
        method, path, _ = lines[0].split(" ", 2)
    except ValueError as exc:
        raise ConnectionError("malformed HTTP request line") from exc
    headers = {}
    for line in lines[1:]:
        if ":" in line:
            k, v = line.split(":", 1)
            headers[k.strip().lower()] = v.strip()
    return method, path, headers, rest


class _SocketLease:
    def __init__(self, sock, permits, active, active_lock):
        self.sock = sock
        self.permits = permits
        self.active = active
        self.active_lock = active_lock
        self.released = False
        with active_lock:
            active.add(sock)

    def replace(self, sock) -> None:
        with self.active_lock:
            self.active.discard(self.sock)
            self.sock = sock
            self.active.add(sock)

    def release(self) -> None:
        with self.active_lock:
            if self.released:
                return
            self.released = True
            self.active.discard(self.sock)
        self.permits.release()

    def close(self) -> None:
        try:
            self.sock.close()
        except OSError:
            pass


def _handle_server_conn(endpoint, conn, public_url, ttl_secs, release) -> bool:
    _method, path, headers, rest = _read_http_head(conn)
    if path == "/.well-known/hop":
        body = well_known_body(endpoint, public_url, ttl_secs).encode()
        conn.sendall(
            b"HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: "
            + str(len(body)).encode()
            + b"\r\nconnection: close\r\n\r\n"
            + body
        )
        return False
    if path != "/_hop" or headers.get("upgrade", "").lower() != "websocket":
        conn.sendall(b"HTTP/1.1 404 Not Found\r\nconnection: close\r\n\r\n")
        return False
    key = headers.get("sec-websocket-key")
    if not key:
        raise ConnectionError("missing Sec-WebSocket-Key")
    accept = _accept_key(key)
    conn.sendall(
        (
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
            "Connection: Upgrade\r\nSec-WebSocket-Accept: " + accept + "\r\n\r\n"
        ).encode()
    )
    conn.settimeout(READ_TIMEOUT_S)

    def run_link():
        try:
            _run_link(endpoint, _Conn(conn, rest), "acceptor", mask=False)
        finally:
            release()

    threading.Thread(target=run_link, name="hop-wss-link", daemon=True).start()
    return True


def serve(endpoint, host, port, ssl_context, public_url, ttl_secs=3600):
    """Start bounded HTTPS/WSS workers. Admission remains held for each link because this bearer cannot
    observe Noise authentication completion."""
    lsock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    lsock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    lsock.bind((host, port))
    lsock.listen(MAX_PENDING_CONNECTIONS)
    pending = queue.Queue(maxsize=MAX_PENDING_CONNECTIONS)
    permits = threading.BoundedSemaphore(MAX_PENDING_CONNECTIONS)
    active = set()
    active_lock = threading.Lock()
    closing = threading.Event()

    def close_server():
        if closing.is_set():
            return
        closing.set()
        try:
            lsock.close()
        except OSError:
            pass
        with active_lock:
            sockets = list(active)
        for sock in sockets:
            try:
                sock.close()
            except OSError:
                pass

    endpoint._register_closer(close_server)

    def worker():
        while True:
            if closing.is_set() and pending.empty():
                return
            try:
                lease = pending.get(timeout=0.1)
            except queue.Empty:
                continue
            transferred = False
            try:
                lease.sock.settimeout(HANDSHAKE_TIMEOUT_S)
                conn = ssl_context.wrap_socket(lease.sock, server_side=True)
                lease.replace(conn)
                transferred = _handle_server_conn(endpoint, conn, public_url, ttl_secs, lease.release)
            except (ConnectionError, OSError, TimeoutError, ValueError, KeyError):
                pass
            finally:
                if not transferred:
                    lease.close()
                    lease.release()
                pending.task_done()

    for i in range(HANDSHAKE_WORKERS):
        threading.Thread(target=worker, name=f"hop-wss-handshake-{i}", daemon=True).start()

    def accept_loop():
        while not closing.is_set():
            try:
                raw, _ = lsock.accept()
            except OSError:
                return
            if not permits.acquire(blocking=False):
                raw.close()
                continue
            lease = _SocketLease(raw, permits, active, active_lock)
            if closing.is_set():
                lease.close()
                lease.release()
                return
            try:
                pending.put_nowait(lease)
            except queue.Full:
                lease.close()
                lease.release()

    threading.Thread(target=accept_loop, name="hop-wss-accept", daemon=True).start()
    return lsock


def dial(endpoint, wss_url, ssl_context):
    """Dial a reachable endpoint over WSS (we are the Noise initiator)."""
    u = urlparse(wss_url)
    host, port, path = u.hostname, u.port or 443, u.path or "/_hop"
    raw = socket.create_connection((host, port), timeout=HANDSHAKE_TIMEOUT_S)
    raw.settimeout(HANDSHAKE_TIMEOUT_S)
    conn = ssl_context.wrap_socket(raw, server_hostname=host)
    endpoint._register_closer(conn.close)  # close() ends this link's read loop
    key = base64.b64encode(os.urandom(16)).decode()
    conn.sendall(
        (
            f"GET {path} HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
        ).encode()
    )
    head, rest = _read_http_bytes(conn)
    if b"101" not in head.split(b"\r\n")[0]:
        raise ConnectionError("WS upgrade failed: " + head.split(b"\r\n")[0].decode("latin1"))
    conn.settimeout(READ_TIMEOUT_S)
    threading.Thread(target=_run_link, args=(endpoint, _Conn(conn, rest), "dialer", True), daemon=True).start()
    return conn
