#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$root" <<'PY'
import importlib.util
import tempfile
from pathlib import Path
import sys

root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("pages", root / "tools/pages-path-guard.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

metadata = {
    "packages": [
        {
            "name": "hop-wasm",
            "manifest_path": str(root / "core/hop-wasm/Cargo.toml"),
            "dependencies": [{"name": "hop-core", "source": None}],
        },
        {
            "name": "hop-core",
            "manifest_path": str(root / "core/hop-core/Cargo.toml"),
            "dependencies": [{"name": "serde", "source": "registry"}],
        },
    ]
}
assert module.transitive_workspace_crates(root, metadata) == {
    "core/hop-wasm/**",
    "core/hop-core/**",
}

with tempfile.TemporaryDirectory() as temp:
    workflow = Path(temp) / "pages.yml"
    workflow.write_text(
        "on:\n  push:\n    paths:\n      - 'sim/**'\n      - 'learn/**'\njobs: {}\n",
        encoding="utf-8",
    )
    assert module.workflow_paths(workflow) == ["sim/**", "learn/**"]
    workflow.write_text(
        "on:\n  push:\n    paths:\n      - 'sim/**'\n      - 'sim/**'\njobs: {}\n",
        encoding="utf-8",
    )
    try:
        module.workflow_paths(workflow)
    except module.PagesPathError:
        pass
    else:
        raise AssertionError("duplicate Pages path was accepted")

print("Pages path guard tests passed")
PY
