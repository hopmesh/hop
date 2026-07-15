"""Discovery: bind a name to a Hop address using the domain's TLS cert (WebPKI) plus a
self-certifying reachability record served at /.well-known/hop. See docs/endpoint-sdk.md."""
from __future__ import annotations

import base64
import http.client
import json
import ssl
import time
from urllib.parse import urlparse

from . import _ffi as ffi

WELL_KNOWN_PATH = "/.well-known/hop"


def well_known_body(endpoint, public_url: str, ttl_secs: int = 3600) -> str:
    """The /.well-known/hop JSON: the endpoint's address + a signed reach record for `public_url`."""
    record = endpoint.sign_reach(public_url, ttl_secs)
    return json.dumps(
        {"address": endpoint.address, "endpoint": public_url, "reach": base64.b64encode(record).decode()}
    )


def _ssl_context(insecure_tls: bool) -> ssl.SSLContext:
    ctx = ssl.create_default_context()
    if insecure_tls:  # dev/self-signed only; production validates via WebPKI
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    return ctx


def resolve(base_url: str, insecure_tls: bool = False) -> dict:
    """Fetch + verify base_url's well-known. Returns {address, address_bytes, wss_url}. Raises on a
    missing/malformed/unverified record."""
    u = urlparse(base_url)
    conn = http.client.HTTPSConnection(u.hostname, u.port or 443, context=_ssl_context(insecure_tls), timeout=15)
    try:
        conn.request("GET", WELL_KNOWN_PATH)
        res = conn.getresponse()
        if res.status != 200:
            raise RuntimeError(f"well-known fetch failed: HTTP {res.status}")
        body = json.loads(res.read())
    finally:
        conn.close()
    info = ffi.verify_reach(base64.b64decode(body["reach"]), int(time.time()))
    if not info:
        raise RuntimeError("reach record failed verification (bad signature or expired)")
    return {"address": info["address_b58"], "address_bytes": info["address"], "wss_url": info["endpoint"]}
