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
config = (root / "tools/copybara/copy.bara.sky").read_text()
paths = plan.origin_paths(config, components)

# The trigger set must be a SUPERSET of the export set: every path that travels out in a component's
# export must also be able to fire that export. This is the guard, run against the real config.
assert plan.check_trigger_coverage(components, paths)


def changed(files):
    return sorted(plan.changed_components(files, components, paths))


# changed_components: prefix ownership, including the nested core/hop vs core/hop-core boundary.
cases = [
    (["sdk/node/lib/ffi.mjs", "README.md"], ["hop-sdk-node"]),
    # core/hop and core/hop-core are distinct prefixes, and the Elixir mirror vendors both.
    (["core/hop/src/lib.rs"], ["hop-sdk-elixir", "libhop"]),
    (["core/hop-core/src/lib.rs"], ["hop-core", "hop-sdk-elixir"]),
    (["docs/x.md", ".github/workflows/ci.yml", "tools/copybara/dispatch.py"], []),
    (["services/hop-relayd/main.rs", "sdk/go/x"], ["hop-relayd", "hop-sdk-go"]),
]
for files, expect in cases:
    got = changed(files)
    assert got == sorted(expect), f"changed_components({files}) = {got}, expected {sorted(expect)}"

# The shared export inputs. Every one of these travels into mirrors that own none of its path, so a
# prefix-only trigger exported NOTHING when they changed: a native signing-key rotation left all four
# native mirrors verifying release bundles against the superseded key until an unrelated commit landed
# under one of their prefixes. These four cases fail against prefix-only detection.
native = ["hop-embedded", "hop-sdk-android", "hop-sdk-apple", "hop-sdk-go"]
assert changed(["tools/native-artifacts-public.pem"]) == sorted(native), "key rotation exports nothing"
assert changed(["tools/native-artifacts.py"]) == sorted(native), "native verifier change exports nothing"
assert changed(["sdk/hop.h"]) == sorted(
    ["hop-sdk-android", "hop-sdk-go"]
), "C ABI header change does not reach the two mirrors that carry it"
assert changed(["tools/release-provenance.py"]) == sorted(components), (
    "the release provenance verifier does not reach all mirrors"
)
assert changed(["tools/release-artifact.py"]) == sorted(components), "release artifact helper misses mirrors"
assert changed(["tools/package-export-smoke.py"]) == sorted(components), "export contract helper misses mirrors"
assert changed(["tools/copybara/components.json"]) == sorted(components), "component map misses mirrors"

# A shared path added to origin_files that the matcher cannot fire on must FAIL the guard, not pass
# silently. Both mutations below model that: an unsupported pattern shape, and a component whose
# origin path the matcher is blind to.
mutated = config.replace(
    '    origin_paths = [\n        prefix + "/**",',
    '    origin_paths = [\n        prefix + "/**",\n        "tools/*.py",',
    1,
)
assert mutated != config, "the origin_paths block anchor moved; this self-test is no longer testing it"
try:
    plan.check_trigger_coverage(components, plan.origin_paths(mutated, components))
except SystemExit as error:
    assert "unsupported origin_files pattern" in str(error), f"wrong rejection: {error}"
else:
    raise AssertionError("guard accepted an origin_files pattern shape the trigger cannot match")

# The historical rule (fire only on the component's own subtree prefix) must FAIL the guard. This is
# the regression: under it, the shared export inputs above travelled out but could not fire an export.
subtree_only = {name: [entry["prefix"] + "/**"] for name, entry in components.items()}
try:
    plan.check_trigger_coverage(components, paths, trigger=subtree_only)
except SystemExit as error:
    assert "would NOT export" in str(error), f"wrong rejection: {error}"
else:
    raise AssertionError("guard accepted a subtree-prefix trigger that misses the shared export inputs")

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
