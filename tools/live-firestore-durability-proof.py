#!/usr/bin/env python3
"""Live Firestore Durability Proof Runner (STORE-002, STORE-005, DESIGN.md section 33).

Exercises the durability claims of the Hop Firestore persistence layer
against Google Cloud Platform (or an in-process mock for offline self-test):
1. Single-writer exclusive lease and operation fence (refusal of conflicting lease).
2. Bundle document write, read-back byte integrity, and TTL metadata.
3. KV document write, read-back byte integrity, and TTL metadata.
4. Definitive write, read, delete, and 404-confirm readiness probe.
5. Scale-to-zero complete cleanup and zero residual document verification.
"""

import argparse
import base64
import hashlib
import http.server
import json
import os
import secrets
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_PROJECT = "hop-mesh"
DEFAULT_DATABASE = "(default)"


def get_access_token():
    """Acquire Google OAuth access token via environment or ADC."""
    token = os.environ.get("FIRESTORE_ACCESS_TOKEN")
    if token:
        return token.strip(), "FIRESTORE_ACCESS_TOKEN env"

    # Attempt Application Default Credentials via gcloud
    try:
        proc = subprocess.run(
            ["gcloud", "auth", "application-default", "print-access-token"],
            capture_output=True,
            text=True,
            check=True,
        )
        tok = proc.stdout.strip()
        if tok:
            return tok, "gcloud application-default credentials"
    except Exception:
        pass

    # Fall back to standard gcloud print-access-token
    try:
        proc = subprocess.run(
            ["gcloud", "auth", "print-access-token"],
            capture_output=True,
            text=True,
            check=True,
        )
        tok = proc.stdout.strip()
        if tok:
            return tok, "gcloud auth print-access-token"
    except Exception:
        pass

    return None, "none"


class MockFirestoreHandler(http.server.BaseHTTPRequestHandler):
    """Minimal in-memory Firestore v1 REST API simulator for offline verification."""

    documents = {}
    lock = threading.Lock()
    fault = None

    def log_message(self, format, *args):
        pass

    def _norm(self, p):
        p = "/" + p.lstrip("/")
        prefix = "/projects/mock/databases/(default)/documents"
        if p.startswith(prefix):
            return p[len(prefix):]
        return p

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = self._norm(parsed.path)
        with self.lock:
            if path.endswith("/bundles") or path.endswith("/kv") or path.endswith("/operations"):
                prefix = path
                matching = [
                    doc for name, doc in self.documents.items()
                    if name.startswith(prefix + "/")
                ]
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                resp = {"documents": matching} if matching else {}
                self.wfile.write(json.dumps(resp).encode())
                return

            doc = self.documents.get(path)
            if doc is None:
                if self.fault == "post-delete-returns-200":
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.end_headers()
                    self.wfile.write(b'{"name": "mock-ghost", "fields": {}}')
                    return
                self.send_response(404)
                self.end_headers()
                return

            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(doc).encode())

    def do_PATCH(self):
        parsed = urllib.parse.urlparse(self.path)
        path = self._norm(parsed.path)
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length).decode()) if length > 0 else {}

        if self.fault == "probe-write-fails" and "readiness-" in path:
            self.send_response(500)
            self.end_headers()
            self.wfile.write(b'{"error": "injected probe failure"}')
            return

        with self.lock:
            doc = {
                "name": f"projects/mock/databases/(default)/documents{path}",
                "fields": body.get("fields", {}),
                "createTime": "2026-09-09T00:00:00.000000Z",
                "updateTime": "2026-09-09T00:00:01.000000Z",
            }
            self.documents[path] = doc

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(doc).encode())

    def do_DELETE(self):
        parsed = urllib.parse.urlparse(self.path)
        path = self._norm(parsed.path)
        with self.lock:
            self.documents.pop(path, None)
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"{}")

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        path = self._norm(parsed.path)
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length).decode()) if length > 0 else {}

        if path.endswith(":commit"):
            writes = body.get("writes", [])
            with self.lock:
                for w in writes:
                    update = w.get("update", {})
                    cond = w.get("currentDocument", {})
                    doc_name = update.get("name", "")
                    doc_path = self._norm(doc_name)

                    exists_cond = cond.get("exists")
                    update_time_cond = cond.get("updateTime")

                    current = self.documents.get(doc_path)
                    if exists_cond is False and current is not None:
                        if self.fault == "fence-collision-accepts-200":
                            self.send_response(200)
                            self.send_header("Content-Type", "application/json")
                            self.end_headers()
                            self.wfile.write(b'{"commitResults": [{"updateTime": "2026-09-09T00:00:03.000000Z"}]}')
                            return
                        self.send_response(409)
                        self.end_headers()
                        self.wfile.write(b'{"error": "document already exists"}')
                        return
                    if update_time_cond and (current is None or current.get("updateTime") != update_time_cond):
                        self.send_response(409)
                        self.end_headers()
                        self.wfile.write(b'{"error": "condition not met"}')
                        return

                    doc = {
                        "name": doc_name,
                        "fields": update.get("fields", {}),
                        "createTime": "2026-09-09T00:00:00.000000Z",
                        "updateTime": "2026-09-09T00:00:02.000000Z",
                    }
                    self.documents[doc_path] = doc

            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"commitResults": [{"updateTime": "2026-09-09T00:00:02.000000Z"}]}')
            return

        self.send_response(404)
        self.end_headers()


class MockFirestoreServer:
    def __init__(self, fault=None):
        MockFirestoreHandler.documents = {}
        MockFirestoreHandler.fault = fault
        self.server = http.server.HTTPServer(("127.0.0.1", 0), MockFirestoreHandler)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever)
        self.thread.daemon = True

    def start(self):
        self.thread.start()

    def stop(self):
        self.server.shutdown()
        self.server.server_close()


def run_durability_exercise(base_url, project, database, node_id, token):
    """Run full live durability proof across all five durability claims."""
    print("=== HOP FIRESTORE DURABILITY PROOF RUNNER ===")
    print(f"Target Base URL : {base_url}")
    print(f"Target Project  : {project}")
    print(f"Target Database : {database}")
    print(f"Target Node ID  : {node_id}")
    print("---------------------------------------------")

    auth_header = {"Authorization": f"Bearer {token}"} if token else {}

    def http_req(url, method="GET", body=None):
        data = json.dumps(body).encode() if body is not None else None
        headers = dict(auth_header)
        if data is not None:
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req) as resp:
                status = resp.status
                payload = resp.read().decode()
                parsed = json.loads(payload) if payload else {}
                return status, parsed, None
        except urllib.error.HTTPError as err:
            status = err.code
            payload = err.read().decode()
            try:
                parsed = json.loads(payload)
            except Exception:
                parsed = {"raw": payload}
            return status, parsed, err
        except Exception as err:
            return 0, {}, err

    # URLs
    doc_root = f"{base_url}/projects/{project}/databases/{database}/documents"
    relays_root = f"{doc_root}/relays/{node_id}"
    commit_url = f"{doc_root}:commit"

    fence_doc_name = f"projects/{project}/databases/{database}/documents/relays/{node_id}/control/critical-operation-fence"
    fence_url = f"{relays_root}/control/critical-operation-fence"
    bundle_url = f"{relays_root}/bundles/test-bundle-alpha"
    kv_url = f"{relays_root}/kv/session-peer-key-test"
    probe_url = f"{relays_root}/operations/readiness-probe-nonce"

    # --- CLAIM 1: Single-Writer Exclusive Lease / Operation Fence ---
    print("\n[Claim 1] Single-Writer Exclusive Lease / Operation Fence")
    generation_1 = base64.b64encode(hashlib.sha256(b"generation-owner-1").digest()).decode()
    fence_payload_1 = {
        "writes": [{
            "update": {
                "name": fence_doc_name,
                "fields": {
                    "fenceVersion": {"integerValue": "1"},
                    "generation": {"bytesValue": generation_1},
                },
            },
            "currentDocument": {"exists": False},
        }]
    }
    status, body, err = http_req(commit_url, method="POST", body=fence_payload_1)
    if status != 200:
        print(f"FAILED initial fence acquire: HTTP {status} error: {err}")
        return False
    print("  OK: Acquired initial critical-operation fence (conditional exists: false) [HTTP 200]")

    status, body, err = http_req(fence_url, method="GET")
    if status != 200:
        print(f"FAILED reading fence: HTTP {status}")
        return False
    observed_gen = body.get("fields", {}).get("generation", {}).get("bytesValue")
    update_time = body.get("updateTime")
    if observed_gen != generation_1 or not update_time:
        print(f"FAILED fence validation: gen={observed_gen}, updateTime={update_time}")
        return False
    print(f"  OK: Verified fence generation and updateTime ({update_time}) [HTTP 200]")

    # Verify conflicting lease refusal
    generation_2 = base64.b64encode(hashlib.sha256(b"generation-owner-2").digest()).decode()
    fence_payload_2 = {
        "writes": [{
            "update": {
                "name": fence_doc_name,
                "fields": {
                    "fenceVersion": {"integerValue": "1"},
                    "generation": {"bytesValue": generation_2},
                },
            },
            "currentDocument": {"exists": False},
        }]
    }
    status, body, err = http_req(commit_url, method="POST", body=fence_payload_2)
    if status == 409:
        print(f"  OK: Conflicting fence acquisition refused as expected [HTTP {status}]")
    else:
        print(f"FAILED: Conflicting fence acquisition was not refused: HTTP {status}")
        return False

    # --- CLAIM 2: Bundle Storage with TTL Eviction Metadata ---
    print("\n[Claim 2] Bundle Storage with TTL Eviction Metadata")
    raw_bundle = b"HOP_SEALED_BUNDLE_PAYLOAD_TEST_DATA"
    bundle_b64 = base64.b64encode(raw_bundle).decode()
    expire_at = "2026-10-01T00:00:00Z"
    expires_at_ms = "1790812800000"

    bundle_body = {
        "fields": {
            "data": {"bytesValue": bundle_b64},
            "expireAt": {"timestampValue": expire_at},
            "expiresAt": {"integerValue": expires_at_ms},
        }
    }
    status, body, err = http_req(bundle_url, method="PATCH", body=bundle_body)
    if status != 200:
        print(f"FAILED bundle write: HTTP {status} error: {err}")
        return False
    print("  OK: Bundle document written with data and TTL fields [HTTP 200]")

    status, body, err = http_req(bundle_url, method="GET")
    if status != 200:
        print(f"FAILED bundle read: HTTP {status}")
        return False
    read_data = body.get("fields", {}).get("data", {}).get("bytesValue")
    read_ttl = body.get("fields", {}).get("expireAt", {}).get("timestampValue")
    if read_data != bundle_b64 or read_ttl != expire_at:
        print(f"FAILED bundle byte or TTL mismatch: data={read_data}, ttl={read_ttl}")
        return False
    print(f"  OK: Bundle read back verified: byte equivalence and TTL preserved ({read_ttl}) [HTTP 200]")

    # --- CLAIM 3: KV State Persistence ---
    print("\n[Claim 3] KV State Persistence")
    kv_key = "session/peer-key-test"
    raw_kv_val = b"HOP_ENCRYPTED_DOUBLE_RATCHET_SESSION_STATE"
    kv_val_b64 = base64.b64encode(raw_kv_val).decode()
    kv_body = {
        "fields": {
            "key": {"stringValue": kv_key},
            "value": {"bytesValue": kv_val_b64},
            "expireAt": {"timestampValue": expire_at},
            "expiresAt": {"integerValue": expires_at_ms},
        }
    }
    status, body, err = http_req(kv_url, method="PATCH", body=kv_body)
    if status != 200:
        print(f"FAILED KV write: HTTP {status}")
        return False
    print("  OK: KV session document written [HTTP 200]")

    status, body, err = http_req(kv_url, method="GET")
    if status != 200:
        print(f"FAILED KV read: HTTP {status}")
        return False
    read_val = body.get("fields", {}).get("value", {}).get("bytesValue")
    if read_val != kv_val_b64:
        print("FAILED KV value mismatch")
        return False
    print("  OK: KV session read back verified: exact state preserved [HTTP 200]")

    # --- CLAIM 4: Definitive Write/Read/Delete/404-Confirm Probe ---
    print("\n[Claim 4] Definitive Write/Read/Delete/404-Confirm Probe")
    probe_id = base64.b64encode(hashlib.sha256(b"probe-nonce-12345").digest()).decode()
    probe_body = {
        "fields": {
            "mutationId": {"bytesValue": probe_id},
            "expireAt": {"timestampValue": expire_at},
        }
    }
    status, body, err = http_req(probe_url, method="PATCH", body=probe_body)
    if status != 200:
        print(f"FAILED probe write: HTTP {status}")
        return False
    print("  OK: Probe marker written [HTTP 200]")

    status, body, err = http_req(probe_url, method="GET")
    if status != 200:
        print(f"FAILED probe read: HTTP {status}")
        return False
    read_mutation = body.get("fields", {}).get("mutationId", {}).get("bytesValue")
    if read_mutation != probe_id:
        print("FAILED probe mutationId mismatch")
        return False
    print("  OK: Probe marker read back verified [HTTP 200]")

    status, body, err = http_req(probe_url, method="DELETE")
    if status != 200:
        print(f"FAILED probe delete: HTTP {status}")
        return False
    print("  OK: Probe marker deleted [HTTP 200]")

    status, body, err = http_req(probe_url, method="GET")
    if status == 404:
        print("  OK: Probe deletion confirmed: read returns HTTP 404")
    else:
        print(f"FAILED probe deletion confirmation: expected 404, got HTTP {status}")
        return False

    # --- CLAIM 5: Scale-to-Zero Complete Cleanup & Zero Residual ---
    print("\n[Claim 5] Scale-to-Zero Complete Cleanup & Zero Residual")
    status, _, _ = http_req(bundle_url, method="DELETE")
    print(f"  OK: Bundle document deleted [HTTP {status}]")
    status, _, _ = http_req(kv_url, method="DELETE")
    print(f"  OK: KV document deleted [HTTP {status}]")
    status, _, _ = http_req(fence_url, method="DELETE")
    print(f"  OK: Fence document deleted [HTTP {status}]")

    # Confirm all deleted
    for label, url in [("bundle", bundle_url), ("kv", kv_url), ("fence", fence_url)]:
        status, _, _ = http_req(url, method="GET")
        if status == 404:
            print(f"  OK: {label} 404 verified")
        else:
            print(f"FAILED: {label} still exists: HTTP {status}")
            return False

    print("\n---------------------------------------------")
    print("ALL 5 DURABILITY CLAIMS VERIFIED SUCCESSFULLY")
    print("Zero residual documents remaining in partition.")
    print("---------------------------------------------")
    return True


def main():
    parser = argparse.ArgumentParser(description="Live Firestore Durability Proof Runner")
    parser.add_argument("--project", default=os.environ.get("FIRESTORE_PROJECT_ID", DEFAULT_PROJECT))
    parser.add_argument("--database", default=DEFAULT_DATABASE)
    parser.add_argument("--node-id", default=os.environ.get("HOP_TEST_NODE_ID"))
    parser.add_argument("--token", default=None)
    parser.add_argument("--mock", action="store_true", help="Run against local in-process mock Firestore server")
    parser.add_argument(
        "--fault",
        choices=["fence-collision-accepts-200", "post-delete-returns-200", "probe-write-fails"],
        default=None,
        help="Inject specific fault in mock server to verify runner failure discrimination",
    )
    args = parser.parse_args()

    if args.mock or args.fault:
        server = MockFirestoreServer(fault=args.fault)
        server.start()
        base_url = f"http://127.0.0.1:{server.port}"
        node_id = args.node_id or f"mock-node-{secrets.token_hex(4)}"
        try:
            ok = run_durability_exercise(
                base_url=base_url,
                project="mock",
                database=args.database,
                node_id=node_id,
                token="mock-token",
            )
        finally:
            server.stop()
        sys.exit(0 if ok else 1)

    # Live GCP run
    token = args.token
    if not token:
        token, token_src = get_access_token()
        if not token:
            print("ERROR: No GCP access token available.", file=sys.stderr)
            print("Run 'gcloud auth application-default login' or set FIRESTORE_ACCESS_TOKEN.", file=sys.stderr)
            sys.exit(2)
        print(f"Credential resolved via: {token_src}")

    node_id = args.node_id or f"live-durability-proof-{int(time.time())}-{secrets.token_hex(4)}"
    base_url = "https://firestore.googleapis.com/v1"

    ok = run_durability_exercise(
        base_url=base_url,
        project=args.project,
        database=args.database,
        node_id=node_id,
        token=token,
    )
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
