"""The Internet bearer for a Python endpoint: opaque Hop frames over TCP, core does the Noise. TCP is
a stream, so each drained packet is length-prefixed (4-byte big-endian) and reassembled on the far
side. HNS would resolve a name to host/port/key; here you pass them directly."""
from __future__ import annotations

import socket
import struct
import threading
from itertools import count

from .endpoint import HopEndpoint

_link_seq = count(40000)
MAX_FRAME_BYTES = 1 << 20


def _send_framed(sock: socket.socket, buf: bytes) -> None:
    try:
        sock.sendall(struct.pack(">I", len(buf)) + buf)
    except OSError:
        pass


def _recv_loop(endpoint: HopEndpoint, sock: socket.socket, link: int) -> None:
    buf = b""
    try:
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            buf += chunk
            while len(buf) >= 4:
                (n,) = struct.unpack(">I", buf[:4])
                if n > MAX_FRAME_BYTES:
                    return
                if len(buf) < 4 + n:
                    break
                frame, buf = buf[4 : 4 + n], buf[4 + n :]
                endpoint._deliver(link, frame)
    except OSError:
        pass
    finally:
        endpoint._link_down(link)
        try:
            sock.close()
        except OSError:
            pass


def listen(endpoint: HopEndpoint, port: int, host: str = "0.0.0.0") -> socket.socket:
    """Listen for inbound Hop connections; each accepted socket is one bearer link (we are acceptor)."""
    lsock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    lsock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    lsock.bind((host, port))
    lsock.listen()
    endpoint._register_closer(lsock.close)  # close() stops the accept loop (accept then raises)
    sockets: set[socket.socket] = set()
    sockets_lock = threading.Lock()
    closing = False

    def close_all():
        nonlocal closing
        with sockets_lock:
            closing = True
            current = list(sockets)
        try:
            lsock.close()
        except OSError:
            pass
        for accepted in current:
            try:
                accepted.close()
            except OSError:
                pass

    endpoint._register_closer(close_all)

    def accept_loop():
        while True:
            try:
                sock, _ = lsock.accept()
            except OSError:
                return
            with sockets_lock:
                if closing:
                    sock.close()
                    continue
                sockets.add(sock)
            link = next(_link_seq)
            endpoint._register_link(link, "acceptor", lambda b, s=sock: _send_framed(s, b))
            def receive(s=sock, link_id=link):
                try:
                    _recv_loop(endpoint, s, link_id)
                finally:
                    with sockets_lock:
                        sockets.discard(s)

            threading.Thread(target=receive, daemon=True).start()

    threading.Thread(target=accept_loop, daemon=True).start()
    return lsock


def dial(endpoint: HopEndpoint, host: str, port: int) -> socket.socket:
    """Dial a reachable endpoint (we are the Noise initiator)."""
    sock = socket.create_connection((host, port))
    endpoint._register_closer(sock.close)  # close() ends this link's recv loop
    link = next(_link_seq)
    endpoint._register_link(link, "dialer", lambda b: _send_framed(sock, b))
    threading.Thread(target=_recv_loop, args=(endpoint, sock, link), daemon=True).start()
    return sock
