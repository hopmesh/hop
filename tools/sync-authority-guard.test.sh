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
rejected("wrong repository", workflow.replace('expected = "hopmesh/monorepo"', 'expected = "fork/monorepo"'))
rejected("missing main ref", workflow.replace('os.environ["REF"] == "refs/heads/main"', "True"))
rejected("unprotected ref", workflow.replace('os.environ["REF_PROTECTED"] == "true"', "True"))
rejected("actor replay", workflow.replace('os.environ["ACTOR"] == os.environ["TRIGGERING_ACTOR"]', "True"))
rejected("mutable image", workflow.replace("@sha256:87e2e9089344e64693faebb2ee0ed33b8797358c0420b0fa98325ca611e98679", "", 1))
rejected("broad token", workflow.replace("repositories: ${{ needs.select.outputs.repository }}", "repositories: hop", 1))
rejected("raw input", workflow.replace("SOURCE_TOKEN: ${{ github.token }}", "SOURCE_TOKEN: ${{ inputs.component }}", 1))
rejected("mapping drift", workflow.replace("          - hop-sdk-go\n", "", 1))
# import must pass the sanitized mirror PR ref to copybara; dropping COPYBARA_SOURCEREF trips the check.
rejected(
    "import missing PR ref",
    workflow.replace("COPYBARA_SOURCEREF: ${{ needs.select.outputs.source_ref }}", "", 1),
)
# The human-actor gate may be relaxed ONLY for import. Widening the carve-out to another direction (so a
# bot could trigger a write direction) must be rejected.
rejected(
    "human-actor carve-out widened",
    workflow.replace('if os.environ["DIRECTION"] != "import":', 'if os.environ["DIRECTION"] != "export":'),
)

# auto_export (push path) must stay push-gated and export-only.
rejected("auto_export not push-gated", workflow.replace("if: ${{ github.event_name == 'push' }}", "if: true", 1))
rejected("auto_export write direction", workflow.replace("SYNC_DIRECTION=export ", "SYNC_DIRECTION=import ", 1))
rejected("auto_export skips preflight", workflow.replace("python3 tools/copybara/auto-export-plan.py", "true", 1))
rejected("auto_export broad token", workflow.replace("repositories: ${{ steps.plan.outputs.repos }}", "repositories: hop", 1))

sync_back = (root / "sdk/go/.github/workflows/sync-back.yml").read_text()
guard.check_sync_back_text(sync_back, "hop-sdk-go")


def rejected_sync_back(name, changed):
    try:
        guard.check_sync_back_text(changed, "hop-sdk-go")
    except guard.SyncAuthorityError:
        return
    raise AssertionError(f"sync-back authority guard accepted: {name}")


rejected_sync_back("repository secret fallback", sync_back.replace("      name: component-sync\n", "", 1))
rejected_sync_back("canonical repository drift", sync_back.replace("repositories: monorepo", "repositories: fork"))
rejected_sync_back("mirror code checkout", sync_back.replace("    steps:\n", "    steps:\n      - uses: actions/checkout@" + "0" * 40 + " # v4\n", 1))
rejected_sync_back("component drift", sync_back.replace("component=hop-sdk-go", "component=hop-sdk-apple"))

print("sync authority guard tests passed")
PY
