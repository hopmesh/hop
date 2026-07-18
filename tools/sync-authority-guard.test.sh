#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$root" <<'PY'
import importlib.util
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("sync_guard", root / "tools/sync-authority-guard.py")
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)
workflow = (root / ".github/workflows/sync-components.yml").read_text()
components = json.loads((root / "tools/copybara/components.json").read_text())
guard.check_text(workflow, components)


def rejected(name, changed):
    try:
        guard.check_text(changed, components)
    except guard.SyncAuthorityError:
        return
    raise AssertionError(f"sync authority guard accepted: {name}")


rejected("missing environment", workflow.replace("      name: component-sync\n", "", 1))
rejected("wrong repository", workflow.replace('expected = "hopmesh/hop"', 'expected = "fork/hop"'))
rejected("missing main ref", workflow.replace('os.environ["REF"] == "refs/heads/main"', "True"))
rejected("unprotected ref", workflow.replace('os.environ["REF_PROTECTED"] == "true"', "True"))
rejected("actor replay", workflow.replace('os.environ["ACTOR"] == os.environ["TRIGGERING_ACTOR"]', "True"))
rejected("mutable image", workflow.replace("@sha256:87e2e9089344e64693faebb2ee0ed33b8797358c0420b0fa98325ca611e98679", "", 1))
rejected("broad token", workflow.replace("repositories: ${{ needs.select.outputs.repository }}", "repositories: hop", 1))
rejected("raw input", workflow.replace("SOURCE_TOKEN: ${{ github.token }}", "SOURCE_TOKEN: ${{ inputs.component }}", 1))
rejected("mapping drift", workflow.replace("          - hop-sdk-node\n", "", 1))

sync_back = (root / "core/hop-core/.github/workflows/sync-back.yml").read_text()
guard.check_sync_back_text(sync_back, "hop-core")


def rejected_sync_back(name, changed):
    try:
        guard.check_sync_back_text(changed, "hop-core")
    except guard.SyncAuthorityError:
        return
    raise AssertionError(f"sync-back authority guard accepted: {name}")


rejected_sync_back("repository secret fallback", sync_back.replace("      name: component-sync\n", "", 1))
rejected_sync_back("canonical repository drift", sync_back.replace("repositories: hop", "repositories: fork"))
rejected_sync_back("mirror code checkout", sync_back.replace("    steps:\n", "    steps:\n      - uses: actions/checkout@" + "0" * 40 + " # v4\n", 1))
rejected_sync_back("component drift", sync_back.replace("component=hop-core", "component=hop-wasm"))

print("sync authority guard tests passed")
PY
