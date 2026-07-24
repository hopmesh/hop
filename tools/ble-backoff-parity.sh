#!/usr/bin/env bash
# Keep the BLE dial-backoff schedule identical on Apple and Android.
#
# WHY THIS GUARD EXISTS. The two BLE bearers are separate per-platform packages (a bearer moves opaque
# bytes and deliberately does not link libhop), so unlike the rest of Hop there is no shared Rust core
# forcing them to agree. That freedom already cost us a real bug: Android moved its dial backoff to
# COUNT-based growth after finding that a DELTA-based schedule reset to the floor on every cycle (a
# dial takes DIAL_TIMEOUT 12s to fail, which always outlasts a sub-2s window, so a peer that
# GATT-connects but never yields an L2CAP channel re-dialed every ~13s forever and starved healthy
# peers). Android documented the fix in DialBackoff.kt. Apple kept the broken delta-based version and
# nobody noticed, because nothing checked.
#
# So: `bearers/ble-backoff-vectors.json` is the canonical schedule, and this guard fails if either
# implementation's constants stop matching it. Jitter is excluded on purpose; it is caller-supplied
# and deliberately random, so only the deterministic base is pinned.
#
# This is the cheap substitute for the shared core the bearers cannot have. If a third bearer ever
# grows a dial schedule, add it here rather than trusting review to catch the drift.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VECTORS="${BLE_BACKOFF_VECTORS:-$ROOT/bearers/ble-backoff-vectors.json}"
KOTLIN="${BLE_BACKOFF_KOTLIN:-$ROOT/bearers/android/bearer-ble/src/main/java/sh/hopme/bearers/ble/DialBackoff.kt}"
SWIFT="${BLE_BACKOFF_SWIFT:-$ROOT/bearers/apple/HopBearerBle/Sources/HopBearerBle/BleBearer.swift}"

python3 - "$VECTORS" "$KOTLIN" "$SWIFT" <<'PY'
import json
import re
import sys

vectors_path, kotlin_path, swift_path = sys.argv[1], sys.argv[2], sys.argv[3]
failures = []

try:
    with open(vectors_path) as fh:
        spec = json.load(fh)
except OSError as err:
    sys.exit(f"ble-backoff-parity: cannot read {vectors_path}: {err}")

want = {
    "base_ms": spec["base_ms"],
    "max_ms": spec["max_ms"],
    "quarantine_after": spec["quarantine_after"],
    "quarantine_ms": spec["quarantine_ms"],
}


def read(path):
    try:
        with open(path) as fh:
            return fh.read()
    except OSError as err:
        sys.exit(f"ble-backoff-parity: cannot read {path}: {err}")


def grab(text, pattern, label, path):
    """Pull one numeric constant out of a source file, tolerating _ digit separators."""
    match = re.search(pattern, text, re.M)
    if not match:
        failures.append(f"{path}: could not find {label} (pattern {pattern!r})")
        return None
    return float(match.group(1).replace("_", ""))


kotlin = read(kotlin_path)
swift = read(swift_path)

# Kotlin is in milliseconds.
got_kotlin = {
    "base_ms": grab(kotlin, r"^internal const val BACKOFF_BASE_MS\s*=\s*([0-9_]+)L", "BACKOFF_BASE_MS", kotlin_path),
    "max_ms": grab(kotlin, r"^internal const val BACKOFF_MAX_MS\s*=\s*([0-9_]+)L", "BACKOFF_MAX_MS", kotlin_path),
    "quarantine_after": grab(kotlin, r"^internal const val BACKOFF_QUARANTINE_AFTER\s*=\s*([0-9_]+)", "BACKOFF_QUARANTINE_AFTER", kotlin_path),
    "quarantine_ms": grab(kotlin, r"^internal const val BACKOFF_QUARANTINE_MS\s*=\s*([0-9_]+)L", "BACKOFF_QUARANTINE_MS", kotlin_path),
}

# Swift is in SECONDS, so scale before comparing. Comparing raw numbers here would "pass" a
# schedule that is a thousand times too fast, which is exactly the kind of drift this guard is for.
got_swift = {
    "base_ms": None,
    "max_ms": None,
    "quarantine_after": grab(swift, r"^let BACKOFF_QUARANTINE_AFTER:\s*Int\s*=\s*([0-9_]+)", "BACKOFF_QUARANTINE_AFTER", swift_path),
    "quarantine_ms": None,
}
for key, pattern, label in (
    ("base_ms", r"^let BACKOFF_BASE_S:\s*Double\s*=\s*([0-9_.]+)", "BACKOFF_BASE_S"),
    ("max_ms", r"^let BACKOFF_MAX_S:\s*Double\s*=\s*([0-9_.]+)", "BACKOFF_MAX_S"),
    ("quarantine_ms", r"^let BACKOFF_QUARANTINE_S:\s*Double\s*=\s*([0-9_.]+)", "BACKOFF_QUARANTINE_S"),
):
    seconds = grab(swift, pattern, label, swift_path)
    got_swift[key] = None if seconds is None else seconds * 1000.0

for label, got, path in (("kotlin", got_kotlin, kotlin_path), ("swift", got_swift, swift_path)):
    for key, expected in want.items():
        actual = got.get(key)
        if actual is None:
            continue
        if abs(actual - float(expected)) > 1e-6:
            failures.append(
                f"{path}: {label} {key} is {actual:g}, canonical schedule says {expected} "
                f"(see {vectors_path})"
            )

# The vector table must actually describe the constants it ships with, or the guard checks nothing.
base, cap, qafter, qms = spec["base_ms"], spec["max_ms"], spec["quarantine_after"], spec["quarantine_ms"]
for row in spec["vectors"]:
    n = row["fail_count"]
    exp = base << min(max(n - 1, 0), 20)
    want_ms = min(exp, qms if n >= qafter else cap)
    if row["backoff_ms"] != want_ms:
        failures.append(
            f"{vectors_path}: vector fail_count={n} says {row['backoff_ms']}ms but the "
            f"declared constants produce {want_ms}ms"
        )

if failures:
    print("ble-backoff-parity: FAIL", file=sys.stderr)
    for line in failures:
        print(f"  - {line}", file=sys.stderr)
    sys.exit(1)

print(
    f"ble-backoff-parity: OK (apple + android agree on base={base}ms cap={cap}ms "
    f"quarantine={qms}ms after {qafter} failures, {len(spec['vectors'])} vectors)"
)
PY
