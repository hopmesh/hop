#!/usr/bin/env bash
# Self-test for the mirror-secret checker. The bug it exists to catch was invisible for weeks, so the
# two ways this checker could go blind are pinned here: missing a referenced secret (a false OK, the
# original failure) and ignoring a scope GitHub actually resolves (a false MISSING, which would train
# everyone to ignore it).
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
python3 - "$root" <<'PY'
import importlib.util
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location(
    "check_mirror_secrets", root / "tools/release/check-mirror-secrets.py"
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

# --- it must find every publishing component and the secrets each one references ------------------
reqs = mod.workflow_requirements(root)
components = json.loads((root / "tools/copybara/components.json").read_text())
expected = sorted(
    name
    for name, entry in components.items()
    if (root / entry["prefix"] / ".github/workflows/release.yml").is_file()
)
assert [r["component"] for r in reqs] == expected, "checker drifted from the publishing components"

# Every release workflow mints the provenance token, so both App secrets must be required everywhere.
for entry in reqs:
    for name in ("HOP_SOURCE_APP_ID", "HOP_SOURCE_APP_PRIVATE_KEY"):
        assert name in entry["required"], f"{entry['component']}: {name} not detected as required"
    # And the release job runs in an environment, which is a scope the audit has to consult.
    assert entry["environments"], f"{entry['component']}: no environment detected"

# A component that DOES reference a registry credential must have it picked up, or the parser is only
# matching the two names we happen to look for. Note the npm/PyPI/crates/RubyGems mirrors reference no
# registry secret at all: they publish over OIDC trusted publishing, so the *_TOKEN secrets seeded on
# those repos are unreferenced leftovers, not something this checker should expect.
by_name = {e["component"]: e for e in reqs}
assert "HEX_API_KEY" in by_name["hop-sdk-elixir"]["required"], "registry secret not detected"
assert "PLATFORMIO_AUTH_TOKEN" in by_name["hop-embedded"]["required"], "registry secret not detected"
assert "MAVEN_GPG_KEY" in by_name["hop-sdk-android"]["required"], "registry secret not detected"
# And a token-free (OIDC) mirror must NOT be reported as needing one.
assert "PYPI_API_TOKEN" not in by_name["hop-sdk-python"]["required"], "OIDC mirror wrongly needs a token"

# --- the reference parser -------------------------------------------------------------------------
assert mod.SECRET_REF.findall("app-id: ${{ secrets.FOO_BAR }}") == ["FOO_BAR"]
assert mod.SECRET_REF.findall("${{secrets.A}} and ${{ secrets.B_2 }}") == ["A", "B_2"]
# Lowercase is not a secret reference (GitHub secret names are upper snake), so it must not match.
assert mod.SECRET_REF.findall("${{ secrets.lower }}") == []
assert mod.ENVIRONMENT.findall("    environment: release\n") == ["release"]

# --- org-secret visibility resolution -------------------------------------------------------------
# A `private`-visibility org secret does NOT resolve in a PUBLIC mirror; counting it would report a
# broken mirror as OK, which is the exact blindness that let this ship.
calls = {}


def fake_gh_json(path):
    calls[path] = calls.get(path, 0) + 1
    if path == "orgs/hopmesh/actions/secrets":
        return {
            "secrets": [
                {"name": "ALL_SCOPE", "visibility": "all"},
                {"name": "PRIVATE_SCOPE", "visibility": "private"},
                {"name": "SELECTED_SCOPE", "visibility": "selected"},
            ]
        }
    if path == "orgs/hopmesh/actions/secrets/SELECTED_SCOPE/repositories":
        return {"repositories": [{"name": "hop-sdk-node"}]}
    if path == "repos/hopmesh/hop-sdk-node":
        return {"private": False}   # mirrors are public
    if path == "repos/hopmesh/secret-repo":
        return {"private": True}
    return None


original = mod.gh_json
mod.gh_json = fake_gh_json
try:
    public = mod.org_secret_names_for("hop-sdk-node", cache={})
    assert "ALL_SCOPE" in public, "visibility=all must resolve"
    assert "SELECTED_SCOPE" in public, "selected list including the repo must resolve"
    assert "PRIVATE_SCOPE" not in public, "visibility=private must NOT resolve in a public mirror"

    other = mod.org_secret_names_for("hop-sdk-python", cache={})
    assert "SELECTED_SCOPE" not in other, "selected list excluding the repo must not resolve"

    private_repo = mod.org_secret_names_for("secret-repo", cache={})
    assert "PRIVATE_SCOPE" in private_repo, "visibility=private must resolve in a private repo"
finally:
    mod.gh_json = original

print("mirror secret checker tests passed")
PY
