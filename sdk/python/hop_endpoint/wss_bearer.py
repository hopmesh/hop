"""The WSS Internet bearer for a Python endpoint, in pure stdlib (no third-party deps). A minimal
RFC 6455 WebSocket: the Upgrade handshake + binary framing, over the threaded socket model the TCP
bearer already uses. core does the Noise handshake and all crypto over the frame payloads; one drained
packet is one binary WS message. The server also answers GET /.well-known/hop on the same port, so
attach() wires both in one call."""
from __future__ import annotations

import base64
import hashlib
import os
import socket
import struct
import threading
from itertools import count
from urllib.parse import urlparse

from .discovery import well_known_body

_WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
_link_seq = count(60000)
MAX_FRAME_BYTES = 1 << 20


def _accept_key(key: str) -> str:
    return base64.b64encode(hashlib.sha1((key + _WS_GUID).encode()).digest()).decode()


class _Conn:
    """A socket with a read buffer, so a handshake read never over-consumes into frame bytes."""

    def __init__(self, sock, initial: bytes = b""):
        self.sock = sock
        self.buf = initial

    def recv_exact(self, n: int) -> bytes:
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("closed")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out


def _encode_frame(payload: bytes, mask: bool) -> bytes:
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


def _read_frame(c: _Conn) -> tuple[int, bytes]:
    b0, b1 = c.recv_exact(2)
    opcode = b0 & 0x0F
    masked = b1 & 0x80
    n = b1 & 0x7F
    if n == 126:
        n = struct.unpack(">H", c.recv_exact(2))[0]
    elif n == 127:
        n = struct.unpack(">Q", c.recv_exact(8))[0]
    if n > MAX_FRAME_BYTES:
        raise ConnectionError("WebSocket frame exceeds 1 MiB")
    mk = c.recv_exact(4) if masked else None
    payload = c.recv_exact(n)
    if mk:
        payload = bytes(b ^ mk[i % 4] for i, b in enumerate(payload))
    return opcode, payload


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
            opcode, payload = _read_frame(c)
            if opcode == 0x8:  # close
                break
            if opcode in (0x2, 0x0):  # binary / continuation
                endpoint._deliver(link, payload)
    except (ConnectionError, OSError):
        pass
    finally:
        endpoint._link_down(link)
        try:
            c.sock.close()
        except OSError:
            pass


def _read_http_head(sock) -> tuple[str, str, dict, bytes]:
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = sock.recv(4096)
        if not chunk:
            raise ConnectionError("closed")
        data += chunk
    head, _, rest = data.partition(b"\r\n\r\n")
    lines = head.decode("latin1").split("\r\n")
    method, path, _ = lines[0].split(" ", 2)
    headers = {}
    for line in lines[1:]:
        if ":" in line:
            k, v = line.split(":", 1)
            headers[k.strip().lower()] = v.strip()
    return method, path, headers, rest


def serve(endpoint, host, port, ssl_context, public_url, ttl_secs=3600):
    """Start a threaded HTTPS server: GET /.well-known/hop -> the discovery body, and a WS upgrade on
    /_hop -> a bearer link (acceptor)."""
    lsock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    lsock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    lsock.bind((host, port))
    lsock.listen()
    endpoint._register_closer(lsock.close)  # close() stops the accept loop

    def handle(conn):
        try:
            _method, path, headers, rest = _read_http_head(conn)
            if path == "/.well-known/hop":
                body = well_known_body(endpoint, public_url, ttl_secs).encode()
                conn.sendall(
                    b"HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: "
                    + str(len(body)).encode()
                    + b"\r\nconnection: close\r\n\r\n"
                    + body
                )
                conn.close()
            elif path == "/_hop" and headers.get("upgrade", "").lower() == "websocket":
                accept = _accept_key(headers["sec-websocket-key"])
                conn.sendall(
                    (
                        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                        "Connection: Upgrade\r\nSec-WebSocket-Accept: " + accept + "\r\n\r\n"
                    ).encode()
                )
                _run_link(endpoint, _Conn(conn, rest), "acceptor", mask=False)
            else:
                conn.sendall(b"HTTP/1.1 404 Not Found\r\nconnection: close\r\n\r\n")
                conn.close()
        except (ConnectionError, OSError):
            try:
                conn.close()
            except OSError:
                pass

    def accept_loop():
        while True:
            try:
                raw, _ = lsock.accept()
                conn = ssl_context.wrap_socket(raw, server_side=True)
            except OSError:
                return
            threading.Thread(target=handle, args=(conn,), daemon=True).start()

    threading.Thread(target=accept_loop, daemon=True).start()
    return lsock


def dial(endpoint, wss_url, ssl_context):
    """Dial a reachable endpoint over WSS (we are the Noise initiator)."""
    u = urlparse(wss_url)
    host, port, path = u.hostname, u.port or 443, u.path or "/_hop"
    raw = socket.create_connection((host, port))
    conn = ssl_context.wrap_socket(raw, server_hostname=host)
    endpoint._register_closer(conn.close)  # close() ends this link's read loop
    key = base64.b64encode(os.urandom(16)).decode()
    conn.sendall(
        (
            f"GET {path} HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
        ).encode()
    )
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(4096)
        if not chunk:
            raise ConnectionError("closed during WS handshake")
        data += chunk
    head, _, rest = data.partition(b"\r\n\r\n")
    if b"101" not in head.split(b"\r\n")[0]:
        raise ConnectionError("WS upgrade failed: " + head.split(b"\r\n")[0].decode("latin1"))
    threading.Thread(target=_run_link, args=(endpoint, _Conn(conn, rest), "dialer", True), daemon=True).start()
    return conn
