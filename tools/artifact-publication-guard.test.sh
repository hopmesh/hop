#!/usr/bin/env bash
# Self-test for the artifact publication authority guard. The guard only means something if it
# reddens on the shape the ESP32 release path actually had: a public `gh release create` reachable
# from a build that never proved canonical CI passed for its source sha.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$root" <<'PY'
import importlib.util
import sys
from pathlib import Path

root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("guard", root / "tools/artifact-publication-guard.py")
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)

AUTHORIZED = """\
name: example
jobs:
  authorize-ci:
    steps:
      - run: python3 tools/native-artifacts.py authorize-ci --source-sha "$GITHUB_SHA"
  build:
    needs: authorize-ci
    steps:
      - run: make artifact
  publish:
    needs: [authorize-ci, build]
    steps:
      - run: gh release create "$VERSION" --repo hopmesh/example-artifacts out.a
"""


def rejects(label, text, fragment):
    try:
        guard.check_workflow("example.yml", text)
    except guard.PublicationAuthorityError as error:
        assert fragment in str(error), f"{label}: wrong rejection: {error}"
        return
    raise AssertionError(f"{label}: guard accepted an unauthorized public publication")


assert guard.check_workflow("example.yml", AUTHORIZED) is True, "guard rejected the correct shape"

# The historical shape: publishes, never authorizes. This is the regression.
rejects(
    "no authorization at all",
    AUTHORIZED.replace(
        '      - run: python3 tools/native-artifacts.py authorize-ci --source-sha "$GITHUB_SHA"',
        '      - run: test "$GITHUB_REF" = "refs/heads/main"',
    ),
    "never runs",
)

# Authorization present but not a dependency of the build: the toolchain and the compile still run
# against an unproven commit, and only the publish is gated.
rejects(
    "build does not depend on the authorization",
    AUTHORIZED.replace("  build:\n    needs: authorize-ci\n", "  build:\n"),
    "does not depend on the CI authorization job",
)

# A publish job with no dependency chain at all reaches the public release on its own.
rejects(
    "publish depends on nothing",
    AUTHORIZED.replace("  publish:\n    needs: [authorize-ci, build]\n", "  publish:\n"),
    "does not depend on the CI authorization job",
)

# Depending on the authorization only TRANSITIVELY (publish -> build -> authorize-ci) is fine, and
# must stay fine, or the guard would force redundant `needs:` entries and get worked around.
assert guard.check_workflow(
    "example.yml", AUTHORIZED.replace("    needs: [authorize-ci, build]", "    needs: build")
) is True, "guard rejected a transitively authorized publish"

# A second, hand-rolled implementation of "did CI pass" is not the same authority.
rejects(
    "re-implemented CI check",
    AUTHORIZED.replace(
        "      - run: make artifact",
        '      - run: gh api "repos/x/actions/workflows/ci.yml/runs?head_sha=$GITHUB_SHA"',
    ),
    "re-implements the CI-success check",
)

# A workflow that publishes nothing outside the repo is simply out of scope, not a failure.
assert guard.check_workflow("ci.yml", "name: ci\njobs:\n  test:\n    steps:\n      - run: cargo test\n") is False

# And the real tree passes. It currently has ZERO workflows in scope (libhop-esp-release.yml, the only
# one, was deleted as unprovisionable and superseded by native-artifacts.yml), so the assertion here is
# that the scan runs and reports honestly, NOT that some live path was verified. The fixtures above are
# what prove the rule bites; keep them, because they are now the guard's entire teeth.
in_scope = guard.check(root)
assert isinstance(in_scope, list), "check() no longer reports the in-scope set"
for name in in_scope:
    assert guard.check_workflow(name, (root / ".github/workflows" / name).read_text()) is True

print("artifact publication guard tests passed")
PY
