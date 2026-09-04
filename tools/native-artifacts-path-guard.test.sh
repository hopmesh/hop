#!/usr/bin/env bash
# Self-test for tools/native-artifacts-path-guard.py (PROC-005).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$root" <<'PY'
import importlib.util
import tempfile
from pathlib import Path
import sys

root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("guard", root / "tools/native-artifacts-path-guard.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

# Test required_paths includes core and expected artifacts
required = module.required_paths(root)
assert "core/**" in required
assert "sdk/hop.h" in required
assert "Cargo.toml" in required
assert "Cargo.lock" in required
assert "tools/native-artifacts.py" in required

# Test workflow_paths parsing and duplicate rejection
with tempfile.TemporaryDirectory() as temp:
    workflow = Path(temp) / "native-artifacts.yml"
    workflow.write_text(
        "on:\n  push:\n    paths:\n      - 'core/**'\n      - 'Cargo.toml'\njobs: {}\n",
        encoding="utf-8",
    )
    assert module.workflow_paths(workflow) == ["core/**", "Cargo.toml"]
    workflow.write_text(
        "on:\n  push:\n    paths:\n      - 'core/**'\n      - 'core/**'\njobs: {}\n",
        encoding="utf-8",
    )
    try:
        module.workflow_paths(workflow)
    except module.NativePathError:
        pass
    else:
        raise AssertionError("duplicate path filter was accepted")

print("native-artifacts path guard tests passed")
PY
