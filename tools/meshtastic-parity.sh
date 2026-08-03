#!/usr/bin/env bash
# Keep the Meshtastic bearer wire contract identical on Apple and Android.
#
# WHY THIS GUARD EXISTS. The two Meshtastic bearers are separate per-platform packages (a bearer moves
# opaque bytes and deliberately does not link libhop), so unlike the rest of Hop there is no shared Rust
# core forcing them to agree. But an Apple phone and an Android phone relaying through the SAME LoRa mesh
# only interoperate if they fragment, tag, and address packets byte for byte identically. This is exactly
# the drift the BLE dial-backoff table (bearers/ble-backoff-vectors.json) was created to prevent, applied
# to the new transport BEFORE it can diverge.
#
# So: `bearers/meshtastic-vectors.json` is the canonical contract, and this guard fails if either
# implementation's constants stop matching it, OR if the pinned fragment-count vectors stop matching the
# declared max_chunk. Per bearers/CLAUDE.md, any policy a bearer implements on both platforms belongs in
# that table; this pins the DECISION POINTS (the fragment header layout and the private port range), not
# only the raw numbers.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VECTORS="${MESH_VECTORS:-$ROOT/bearers/meshtastic-vectors.json}"
SWIFT="${MESH_SWIFT:-$ROOT/bearers/apple/HopBearerMeshtastic/Sources/HopBearerMeshtastic/MeshtasticWire.swift}"
KOTLIN="${MESH_KOTLIN:-$ROOT/bearers/android/bearer-meshtastic/src/main/java/sh/hopme/bearers/meshtastic/MeshtasticWire.kt}"

python3 - "$VECTORS" "$SWIFT" "$KOTLIN" <<'PY'
import json
import re
import sys

vectors_path, swift_path, kotlin_path = sys.argv[1], sys.argv[2], sys.argv[3]
failures = []

try:
    with open(vectors_path) as fh:
        spec = json.load(fh)
except OSError as err:
    sys.exit(f"meshtastic-parity: cannot read {vectors_path}: {err}")


def read(path):
    try:
        with open(path) as fh:
            return fh.read()
    except OSError as err:
        sys.exit(f"meshtastic-parity: cannot read {path}: {err}")


def grab(text, pattern, label, path, base=10):
    match = re.search(pattern, text, re.M)
    if not match:
        failures.append(f"{path}: could not find {label} (pattern {pattern!r})")
        return None
    return int(match.group(1).replace("_", ""), base)


swift = read(swift_path)
kotlin = read(kotlin_path)

# --- plain integer constants both platforms declare identically --------------------------------------
int_consts = {
    "hop_portnum": (
        r"^let MESH_HOP_PORTNUM: UInt32 = ([0-9]+)",
        r"^internal const val MESH_HOP_PORTNUM = ([0-9]+)",
    ),
    "max_chunk": (
        r"^let MESH_MAX_CHUNK = ([0-9]+)",
        r"^internal const val MESH_MAX_CHUNK = ([0-9]+)",
    ),
    "frag_header": (
        r"^let MESH_FRAG_HEADER = ([0-9]+)",
        r"^internal const val MESH_FRAG_HEADER = ([0-9]+)",
    ),
    "max_frags": (
        r"^let MESH_MAX_FRAGS = ([0-9]+)",
        r"^internal const val MESH_MAX_FRAGS = ([0-9]+)",
    ),
}
for key, (swp, kop) in int_consts.items():
    want = spec[key]
    sv = grab(swift, swp, key, swift_path)
    kv = grab(kotlin, kop, key, kotlin_path)
    if sv is not None and sv != want:
        failures.append(f"{swift_path}: {key} is {sv}, canonical says {want} (see {vectors_path})")
    if kv is not None and kv != want:
        failures.append(f"{kotlin_path}: {key} is {kv}, canonical says {want} (see {vectors_path})")

# --- the Hop link-frame type tags (hex on both platforms) --------------------------------------------
frame_consts = {
    "hello": (r"^let M_HELLO: UInt8 = 0x([0-9a-fA-F]+)", r"^internal const val M_HELLO = 0x([0-9a-fA-F]+)"),
    "ping": (r"^let M_PING: UInt8 = 0x([0-9a-fA-F]+)", r"^internal const val M_PING = 0x([0-9a-fA-F]+)"),
    "pong": (r"^let M_PONG: UInt8 = 0x([0-9a-fA-F]+)", r"^internal const val M_PONG = 0x([0-9a-fA-F]+)"),
    "data": (r"^let M_DATA: UInt8 = 0x([0-9a-fA-F]+)", r"^internal const val M_DATA = 0x([0-9a-fA-F]+)"),
}
for key, (swp, kop) in frame_consts.items():
    want = spec["frames"][key]
    sv = grab(swift, swp, f"M_{key.upper()}", swift_path, base=16)
    kv = grab(kotlin, kop, f"M_{key.upper()}", kotlin_path, base=16)
    if sv is not None and sv != want:
        failures.append(f"{swift_path}: frame tag {key} is 0x{sv:x}, canonical says {want}")
    if kv is not None and kv != want:
        failures.append(f"{kotlin_path}: frame tag {key} is 0x{kv:x}, canonical says {want}")

# --- liveness timing: Swift is in SECONDS, Kotlin in MILLISECONDS ------------------------------------
# Scale before comparing. Comparing raw numbers would "pass" a keepalive 1000x too fast, exactly the kind
# of unit confusion this guard is for.
for key, swp, kop in (
    ("ping_ms", r"^let MESH_PING_S: Double = ([0-9.]+)", r"^internal const val MESH_PING_MS = ([0-9_]+)L"),
    ("dead_ms", r"^let MESH_DEAD_S: Double = ([0-9.]+)", r"^internal const val MESH_DEAD_MS = ([0-9_]+)L"),
):
    want = spec[key]
    m = re.search(swp, swift, re.M)
    if not m:
        failures.append(f"{swift_path}: could not find {key} (pattern {swp!r})")
    else:
        got = float(m.group(1)) * 1000.0
        if abs(got - want) > 1e-6:
            failures.append(f"{swift_path}: {key} is {got:g}ms, canonical says {want}ms")
    kv = grab(kotlin, kop, key, kotlin_path)
    if kv is not None and kv != want:
        failures.append(f"{kotlin_path}: {key} is {kv}ms, canonical says {want}ms")

# --- decision point 1: the Hop port must live in the Meshtastic PRIVATE_APP range (256..511) ---------
# Pinning the number alone is not enough: a first-party Meshtastic PortNum (below 256) would collide with
# real Meshtastic apps on the mesh. This asserts the CHOICE, not just the value.
port = spec["hop_portnum"]
if not (256 <= port <= 511):
    failures.append(
        f"{vectors_path}: hop_portnum {port} is outside the Meshtastic PRIVATE_APP range 256..511"
    )

# --- decision point 2: the fragment vectors must follow from max_chunk ------------------------------
# A change to max_chunk silently reshapes every packet on the wire. Recompute the fragment count for each
# pinned length and fail if the table no longer matches its own declared chunk size.
chunk = spec["max_chunk"]
for row in spec["fragment_vectors"]:
    n, frags = row["len"], row["frags"]
    want_frags = 1 if n == 0 else (n + chunk - 1) // chunk
    if frags != want_frags:
        failures.append(
            f"{vectors_path}: fragment vector len={n} says {frags} frags but max_chunk={chunk} "
            f"produces {want_frags}"
        )

if failures:
    print("meshtastic-parity: FAIL", file=sys.stderr)
    for line in failures:
        print(f"  - {line}", file=sys.stderr)
    sys.exit(1)

print(
    f"meshtastic-parity: OK (apple + android agree on port={port} chunk={chunk}B "
    f"header={spec['frag_header']}B ping={spec['ping_ms']}ms dead={spec['dead_ms']}ms, "
    f"{len(spec['fragment_vectors'])} fragment vectors)"
)
PY
