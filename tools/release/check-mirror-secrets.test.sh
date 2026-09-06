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
# The positive cases (Hex, PlatformIO, Maven) named hop-sdk-elixir, hop-embedded and hop-sdk-android,
# all retired in 2026-08. They have no replacement: EVERY live mirror distributes by git tag
# (SwiftPM for the SDK and the bearers, shards, the Go proxy), so not one of them references a
# registry credential. Asserting a positive detection now would need a fabricated fixture, which would
# test the fixture rather than the parser. Restore these alongside any future mirror that carries a
# registry secret.
#
# The negative case survives and is retargeted, because it still has a real subject: a mirror that
# needs no registry token must not be reported as needing one. That is the direction that matters
# here, since a false positive would send someone seeding a secret that nothing reads.
for _component in sorted(by_name):
    for _token in ("HEX_API_KEY", "PLATFORMIO_AUTH_TOKEN", "MAVEN_GPG_KEY", "PYPI_API_TOKEN", "NPM_TOKEN"):
        assert _token not in by_name[_component]["required"], (
            f"{_component} publishes by git tag and needs no registry credential, "
            f"but the audit reports {_token} as required"
        )

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
        return {"repositories": [{"name": "hop-sdk-go"}]}
    if path == "repos/hopmesh/hop-sdk-go":
        return {"private": False}   # mirrors are public
    if path == "repos/hopmesh/secret-repo":
        return {"private": True}
    return None


original = mod.gh_json
mod.gh_json = fake_gh_json
try:
    public = mod.org_secret_names_for("hop-sdk-go", cache={})
    assert "ALL_SCOPE" in public, "visibility=all must resolve"
    assert "SELECTED_SCOPE" in public, "selected list including the repo must resolve"
    assert "PRIVATE_SCOPE" not in public, "visibility=private must NOT resolve in a public mirror"

    other = mod.org_secret_names_for("hop-sdk-crystal", cache={})
    assert "SELECTED_SCOPE" not in other, "selected list excluding the repo must not resolve"

    private_repo = mod.org_secret_names_for("secret-repo", cache={})
    assert "PRIVATE_SCOPE" in private_repo, "visibility=private must resolve in a private repo"
finally:
    mod.gh_json = original

# --- audit verdict: missing secrets must fail, complete secrets must pass --------------------------
def fake_gh_json_missing(path):
    if "secrets" in path:
        return {"secrets": []}
    return None

mod.gh_json = fake_gh_json_missing
try:
    findings = mod.audit(root)
    broken = [entry for entry in findings if entry["missing"]]
    assert len(broken) == len(findings), "all mirrors must be flagged when no secrets are seeded"
    for entry in broken:
        assert "HOP_SOURCE_APP_ID" in entry["missing"], f"{entry['component']} must report missing APP_ID"
        assert "HOP_SOURCE_APP_PRIVATE_KEY" in entry["missing"], f"{entry['component']} must report missing private key"
finally:
    mod.gh_json = original

def fake_gh_json_all_seeded(path):
    if "secrets" in path:
        return {
            "secrets": [
                {"name": "HOP_SOURCE_APP_ID", "visibility": "all"},
                {"name": "HOP_SOURCE_APP_PRIVATE_KEY", "visibility": "all"},
                {"name": "COCOAPODS_TRUNK_TOKEN", "visibility": "all"},
            ]
        }
    return None

mod.gh_json = fake_gh_json_all_seeded
try:
    findings = mod.audit(root)
    broken = [entry for entry in findings if entry["missing"]]
    assert len(broken) == 0, f"audit must pass when all secrets are seeded, got {broken}"
finally:
    mod.gh_json = original
# Verify workflow wrapper declared-disarmed pattern (INFRA-020)
import subprocess, tempfile
workflow = root / ".github/workflows/branch-protection-audit.yml"
import re
text = workflow.read_text(encoding="utf-8")
match = re.search(r"mirror-secrets:.*?steps:.*?run: \|\n(.*?)(?=^\s+[A-Za-z0-9_-]+:|\Z)", text, re.S)
assert match, "mirror-secrets step not found"
step = "\n".join(line[10:] for line in match.group(1).splitlines())

# Case 1: unprovisioned declared in manifest -> warns as declared-disarmed, exits 0
res = subprocess.run(["bash", "-c", step], cwd=str(root), capture_output=True, text=True)
assert res.returncode == 0, f"mirror-secrets step must exit 0 when declared unprovisioned, got {res.returncode}: {res.stderr}"
assert "mirror-secret audit declared-disarmed" in res.stdout or "mirror-secret audit declared-disarmed" in res.stderr

# Case 2: manifest claims provisioned: true but secret is empty -> fails closed with exit 1
step_armed = step.replace("tools/workflow-secrets.json", "$ARMED_MANIFEST")
with tempfile.NamedTemporaryFile("w", suffix=".json") as tf:
    manifest = json.loads((root / "tools/workflow-secrets.json").read_text())
    manifest["secrets"]["MIRROR_SECRET_AUDIT_TOKEN"]["provisioned"] = True
    json.dump(manifest, tf)
    tf.flush()
    res_armed = subprocess.run(
        ["bash", "-c", f"ARMED_MANIFEST={tf.name} {step_armed}"],
        cwd=str(root),
        capture_output=True,
        text=True,
    )
    assert res_armed.returncode != 0, f"mirror-secrets step must fail when armed but unseeded, got {res_armed.returncode}"
    assert "mirror-secret audit is armed but unseeded" in res_armed.stdout or "mirror-secret audit is armed but unseeded" in res_armed.stderr

# --- mirror protection tests (INFRA-019) -----------------------------------------------------------
def fake_prot_unprotected(path):
    return None

mod.gh_json = fake_prot_unprotected
try:
    assert mod.mirror_branch_protection("hop-sdk-crystal") == "main branch is not protected"
    assert mod.mirror_environment_protection("hop-sdk-crystal", "release") == "environment 'release' is not configured"
finally:
    mod.gh_json = original

def fake_prot_partial(path):
    if "branches/main/protection" in path:
        return {
            "enforce_admins": {"enabled": False},
            "allow_force_pushes": {"enabled": False},
            "allow_deletions": {"enabled": False},
        }
    if "environments/release" in path:
        return {"protection_rules": [], "deployment_branch_policy": None}
    return None

mod.gh_json = fake_prot_partial
try:
    assert "does not enforce admin parity" in mod.mirror_branch_protection("hop-sdk-crystal")
    assert "lacks required reviewer 'jwaldrip'" in mod.mirror_environment_protection("hop-sdk-crystal", "release")
finally:
    mod.gh_json = original

def fake_prot_allow_force(path):
    if "branches/main/protection" in path:
        return {
            "enforce_admins": {"enabled": True},
            "allow_force_pushes": {"enabled": True},
            "allow_deletions": {"enabled": False},
        }
    return None

mod.gh_json = fake_prot_allow_force
try:
    assert "does not block force pushes" in mod.mirror_branch_protection("hop-sdk-crystal")
finally:
    mod.gh_json = original

def fake_prot_allow_del(path):
    if "branches/main/protection" in path:
        return {
            "enforce_admins": {"enabled": True},
            "allow_force_pushes": {"enabled": False},
            "allow_deletions": {"enabled": True},
        }
    return None

mod.gh_json = fake_prot_allow_del
try:
    assert "does not block deletions" in mod.mirror_branch_protection("hop-sdk-crystal")
finally:
    mod.gh_json = original

def fake_prot_healthy(path):
    if "branches/main/protection" in path:
        return {
            "enforce_admins": {"enabled": True},
            "allow_force_pushes": {"enabled": False},
            "allow_deletions": {"enabled": False},
        }
    if "environments/release" in path:
        return {
            "protection_rules": [{"type": "required_reviewers", "reviewers": [{"reviewer": {"login": "jwaldrip"}}]}],
            "deployment_branch_policy": {"custom_branch_policies": True},
        }
    return None

mod.gh_json = fake_prot_healthy
try:
    assert mod.mirror_branch_protection("hop-sdk-crystal") is None
    assert mod.mirror_environment_protection("hop-sdk-crystal", "release") is None
finally:
    mod.gh_json = original

# --- canonical app installation tests (INFRA-023) --------------------------------------------------
orig_gh_get = mod.gh_get

# Case 1: 401 on the org-installations lookup -> message says the token cannot read org installations,
# and does NOT contain "not installed".
print("case: 401 on org installations lookup")
mod.gh_get = lambda path, paginate=False: (401, None)
try:
    msg = mod.canonical_app_installation()
    assert msg is not None, "expected issue message on 401"
    assert "org installations unreadable with this token" in msg, f"unexpected message: {msg}"
    assert "needs admin:org" in msg, f"message must mention admin:org, got: {msg}"
    assert "not installed" not in msg, f"401 must not produce 'not installed' wording, got: {msg}"
finally:
    mod.gh_get = orig_gh_get

# Case 2: org installations readable, hop-source absent -> "not installed on the hopmesh organization"
print("case: hop-source absent from org installations")
mod.gh_get = lambda path, paginate=False: (
    200,
    [{"installations": [{"app_slug": "other-app", "id": 1}]}],
)
try:
    msg = mod.canonical_app_installation()
    assert msg is not None, "expected issue message when hop-source absent"
    assert "not installed on the hopmesh organization" in msg, f"unexpected message: {msg}"
finally:
    mod.gh_get = orig_gh_get

# Case 3: present with repository_selection: all and full permissions -> None
print("case: hop-source present with repository_selection all")
mod.gh_get = lambda path, paginate=False: (
    200,
    [
        {
            "installations": [
                {
                    "id": 149989111,
                    "app_slug": "hop-source",
                    "repository_selection": "all",
                    "permissions": {
                        "actions": "read",
                        "checks": "read",
                        "contents": "read",
                    },
                }
            ]
        }
    ],
)
try:
    assert mod.canonical_app_installation() is None
finally:
    mod.gh_get = orig_gh_get

# Case 4: present, selected, repositories list contains hopmesh/hop -> None
print("case: hop-source present with repository_selection selected and hopmesh/hop included")
def fake_gh_get_selected_ok(path, paginate=False):
    if "installations" in path and "user" not in path:
        return (
            200,
            [
                {
                    "installations": [
                        {
                            "id": 149989111,
                            "app_slug": "hop-source",
                            "repository_selection": "selected",
                            "permissions": {
                                "actions": "read",
                                "checks": "read",
                                "contents": "read",
                            },
                        }
                    ]
                }
            ],
        )
    if "user/installations/149989111/repositories" in path:
        return (
            200,
            [
                {
                    "repositories": [
                        {"name": "hop", "full_name": "hopmesh/hop"}
                    ]
                }
            ],
        )
    return (404, None)

mod.gh_get = fake_gh_get_selected_ok
try:
    assert mod.canonical_app_installation() is None
finally:
    mod.gh_get = orig_gh_get

# Case 5: present, selected, repositories list lacks hopmesh/hop -> message names hopmesh/hop as not selected
print("case: hop-source present with repository_selection selected and hopmesh/hop not selected")
def fake_gh_get_selected_missing_hop(path, paginate=False):
    if "installations" in path and "user" not in path:
        return (
            200,
            [
                {
                    "installations": [
                        {
                            "id": 149989111,
                            "app_slug": "hop-source",
                            "repository_selection": "selected",
                            "permissions": {
                                "actions": "read",
                                "checks": "read",
                                "contents": "read",
                            },
                        }
                    ]
                }
            ],
        )
    if "user/installations/149989111/repositories" in path:
        return (
            200,
            [
                {
                    "repositories": [
                        {"name": "other-repo", "full_name": "hopmesh/other-repo"}
                    ]
                }
            ],
        )
    return (404, None)

mod.gh_get = fake_gh_get_selected_missing_hop
try:
    msg = mod.canonical_app_installation()
    assert msg is not None, "expected issue message when hopmesh/hop not selected"
    assert "hopmesh/hop" in msg and "not selected" in msg, (
        f"message must name hopmesh/hop as not selected, got: {msg}"
    )
finally:
    mod.gh_get = orig_gh_get

# Case 6: present, selected, repositories lookup 403 -> selection unreadable (read:user) and does NOT contain "not installed"
print("case: hop-source present with repository_selection selected and repositories lookup 403")
def fake_gh_get_selected_403(path, paginate=False):
    if "installations" in path and "user" not in path:
        return (
            200,
            [
                {
                    "installations": [
                        {
                            "id": 149989111,
                            "app_slug": "hop-source",
                            "repository_selection": "selected",
                            "permissions": {
                                "actions": "read",
                                "checks": "read",
                                "contents": "read",
                            },
                        }
                    ]
                }
            ],
        )
    if "user/installations/149989111/repositories" in path:
        return (403, None)
    return (404, None)

mod.gh_get = fake_gh_get_selected_403
try:
    msg = mod.canonical_app_installation()
    assert msg is not None, "expected issue message on 403 repositories lookup"
    assert "read:user" in msg, f"message must mention read:user, got: {msg}"
    assert "selection unreadable" in msg or "selected repositories unreadable" in msg, (
        f"message must state selection unreadable, got: {msg}"
    )
    assert "not installed" not in msg, f"403 must not produce 'not installed' wording, got: {msg}"
finally:
    mod.gh_get = orig_gh_get

# Case 7: present with contents: none -> message lists contents:read as missing
print("case: hop-source present with missing permissions")
mod.gh_get = lambda path, paginate=False: (
    200,
    [
        {
            "installations": [
                {
                    "id": 149989111,
                    "app_slug": "hop-source",
                    "repository_selection": "all",
                    "permissions": {
                        "actions": "read",
                        "checks": "read",
                        "contents": "none",
                    },
                }
            ]
        }
    ],
)
try:
    msg = mod.canonical_app_installation()
    assert msg is not None, "expected issue message on missing permissions"
    assert "contents:read" in msg, f"message must list contents:read as missing, got: {msg}"
    assert "missing permissions" in msg, f"expected 'missing permissions' in msg, got: {msg}"
finally:
    mod.gh_get = orig_gh_get

print("mirror secret checker tests passed")
PY
