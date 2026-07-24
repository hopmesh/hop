#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
python3 - "$root" <<'PY'
import importlib.util
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("plan", root / "tools/copybara/auto-export-plan.py")
plan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(plan)
components = json.loads((root / "tools/copybara/components.json").read_text())

# changed_components: prefix ownership, including the nested core/hop vs core/hop-core boundary.
cases = [
    (["sdk/node/lib/ffi.mjs", "README.md"], ["hop-sdk-node"]),
    (["core/hop/src/lib.rs"], ["libhop"]),
    (["core/hop-core/src/lib.rs"], ["hop-core"]),
    (["core/hop-core/a", "core/hop/b"], ["hop-core", "libhop"]),
    (["docs/x.md", ".github/workflows/ci.yml", "tools/copybara/dispatch.py"], []),
    (["services/hop-relayd/main.rs", "sdk/go/x"], ["hop-relayd", "hop-sdk-go"]),
]
for files, expect in cases:
    got = sorted(plan.changed_components(files, components))
    assert got == sorted(expect), f"changed_components({files}) = {got}, expected {sorted(expect)}"

# preflight rejects anything that is not a push to canonical protected main (no network on the fast path:
# every rejection here is a local check that fires before the API call).
base = {
    "REPOSITORY": "hopmesh/monorepo",
    "EVENT_REPOSITORY": "hopmesh/monorepo",
    "EVENT_NAME": "push",
    "REF": "refs/heads/main",
    "DEFAULT_BRANCH": "main",
    "REF_PROTECTED": "true",
    "SHA": "0" * 40,
    "GH_TOKEN": "x",
}
for tweak in (
    {"EVENT_NAME": "workflow_dispatch"},
    {"REF": "refs/heads/dev"},
    {"REF_PROTECTED": "false"},
    {"REPOSITORY": "fork/monorepo"},
    {"EVENT_REPOSITORY": "fork/monorepo"},
    {"DEFAULT_BRANCH": "dev"},
    {"SHA": "nothex"},
):
    env = dict(base, **tweak)
    try:
        plan.preflight(env)
    except SystemExit:
        continue
    raise AssertionError(f"preflight accepted a non-canonical push: {tweak}")

print("auto-export plan tests passed")
PY
