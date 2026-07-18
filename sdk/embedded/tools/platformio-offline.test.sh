#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../../.." && pwd)"
python3 - "$root" <<'PY'
import importlib.util
import json
import tempfile
from pathlib import Path
import sys

root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("offline", root / "sdk/embedded/tools/platformio-offline.py")
offline = importlib.util.module_from_spec(spec)
spec.loader.exec_module(offline)
lock_path = root / "sdk/embedded/platformio-packages.lock.json"
lock = offline.load_lock(lock_path)
expected = {entry["reference"] for entry in lock["packages"]}
assert offline.config_uri(Path("archive+build.tar.gz")).endswith("archive+build.tar.gz")
assert offline.local_reference(lock["packages"][0], Path("platform.tar.gz")).startswith("file://")
assert " @ file://" in offline.local_reference(lock["packages"][1], Path("tool.tar.gz"))
for name in ("blink_send", "service_rpc"):
    config = root / "sdk/embedded/examples" / name / "platformio.ini"
    assert set(offline.config_references(config.read_text())) == expected

bad = json.loads(lock_path.read_text())
bad["packages"][0]["sha256"] = "0" * 63
with tempfile.TemporaryDirectory() as temp:
    path = Path(temp) / "lock.json"
    path.write_text(json.dumps(bad))
    try:
        offline.load_lock(path)
    except offline.OfflineError:
        pass
    else:
        raise AssertionError("malformed PlatformIO digest was accepted")

bad = json.loads(lock_path.read_text())
bad["packages"][0]["url"] = "https://attacker.example/tool.tar.gz"
with tempfile.TemporaryDirectory() as temp:
    path = Path(temp) / "lock.json"
    path.write_text(json.dumps(bad))
    try:
        offline.load_lock(path)
    except offline.OfflineError:
        pass
    else:
        raise AssertionError("unapproved PlatformIO download host was accepted")

print("PlatformIO offline input tests passed")
PY
