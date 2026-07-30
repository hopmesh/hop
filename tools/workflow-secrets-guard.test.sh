#!/usr/bin/env bash
# Self-test for the workflow secret-scope guard. It has to redden on the exact historical shape: a
# workflow reading a secret name provisioned in no scope, and a job reading an environment-scoped name
# without declaring that environment. Names only appear here; no secret value is used anywhere.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$root" <<'PY'
import importlib.util
import json
import shutil
import sys
import tempfile
from pathlib import Path

root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("guard", root / "tools/workflow-secrets-guard.py")
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)

# The real tree must pass, and must actually be checking something.
declared = guard.check_static(root)
assert declared, "the secret manifest is empty, so this guard would be vacuously green"

# Job environment parsing, both YAML shapes plus the absent case.
assert guard.job_environment("    environment: release\n") == "release"
assert guard.job_environment("    environment:\n      name: component-sync\n") == "component-sync"
assert guard.job_environment("    runs-on: ubuntu-latest\n") is None


def sandbox():
    work = Path(tempfile.mkdtemp())
    (work / ".github/workflows").mkdir(parents=True)
    (work / "tools").mkdir()
    shutil.copy(root / "tools/workflow-secrets.json", work / "tools/workflow-secrets.json")
    return work


def rejects(label, workflow_text, manifest_edit, fragment):
    work = sandbox()
    try:
        (work / ".github/workflows/example.yml").write_text(workflow_text, encoding="utf-8")
        manifest = json.loads((work / "tools/workflow-secrets.json").read_text())
        manifest["secrets"] = manifest_edit(manifest["secrets"])
        (work / "tools/workflow-secrets.json").write_text(json.dumps(manifest), encoding="utf-8")
        try:
            guard.check_static(work)
        except guard.WorkflowSecretsError as error:
            assert fragment in str(error), f"{label}: wrong rejection: {error}"
            return
        raise AssertionError(f"{label}: guard accepted it")
    finally:
        shutil.rmtree(work)


ONLY_KNOWN = """\
name: example
jobs:
  publish:
    environment:
      name: component-sync
    steps:
      - uses: actions/create-github-app-token@v3
        with:
          app-id: ${{ secrets.HOP_SYNC_APP_ID }}
          private-key: ${{ secrets.HOP_SYNC_APP_PRIVATE_KEY }}
"""

# A workflow reading names that appear in NO scope and in no inventory. This is the ESP32 release
# path's historical shape: HOP_RELEASE_APP_ID and HOP_RELEASE_APP_PRIVATE_KEY were referenced by a
# workflow, set in no scope, and recorded nowhere, so the path silently could not run.
rejects(
    "undeclared secret names",
    ONLY_KNOWN.replace("HOP_SYNC_APP_ID", "HOP_GHOST_APP_ID").replace(
        "HOP_SYNC_APP_PRIVATE_KEY", "HOP_GHOST_APP_PRIVATE_KEY"
    ),
    lambda secrets: {},
    "no scope is declared for",
)

# The same names, provisioned only in an environment the reading job does not declare. This is the
# other half of the same defect: present somewhere, unreadable here.
rejects(
    "environment-scoped secret read from the wrong environment",
    ONLY_KNOWN.replace("      name: component-sync", "      name: release"),
    lambda secrets: {
        name: entry
        for name, entry in secrets.items()
        if name in ("HOP_SYNC_APP_ID", "HOP_SYNC_APP_PRIVATE_KEY")
    },
    "but the job declares environment release",
)

rejects(
    "environment-scoped secret read from a job with no environment",
    ONLY_KNOWN.replace("    environment:\n      name: component-sync\n", ""),
    lambda secrets: {
        name: entry
        for name, entry in secrets.items()
        if name in ("HOP_SYNC_APP_ID", "HOP_SYNC_APP_PRIVATE_KEY")
    },
    "but the job declares no environment",
)

# A manifest entry no workflow reads is stale and must be reported, so the file stays a real inventory.
rejects(
    "stale manifest entry",
    ONLY_KNOWN,
    lambda secrets: {
        **{
            name: entry
            for name, entry in secrets.items()
            if name in ("HOP_SYNC_APP_ID", "HOP_SYNC_APP_PRIVATE_KEY")
        },
        "RETIRED_TOKEN": {"scope": "repository", "purpose": "nothing reads this"},
    },
    "declares unused secret names",
)

# secrets.GITHUB_TOKEN is runner-issued, provisioned by nobody, and must not need a manifest entry.
work = sandbox()
try:
    (work / ".github/workflows/example.yml").write_text(
        "name: example\njobs:\n  x:\n    steps:\n      - env:\n          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}\n",
        encoding="utf-8",
    )
    manifest = json.loads((work / "tools/workflow-secrets.json").read_text())
    manifest["secrets"] = {}
    (work / "tools/workflow-secrets.json").write_text(json.dumps(manifest), encoding="utf-8")
    guard.check_static(work)
finally:
    shutil.rmtree(work)

# A bare "secrets.json" in a comment is prose, not a read, and must not be mistaken for a secret name.
assert guard.secret_names("# tools/workflow-secrets.json records it\n") == set()
assert guard.secret_names("app-id: ${{ secrets.HOP_SYNC_APP_ID }}\n") == {"HOP_SYNC_APP_ID"}

# provisioned:false is a declared to-do, not an exemption. It must carry a reason...
rejects(
    "provisioned:false with no reason",
    ONLY_KNOWN,
    lambda secrets: {
        name: (
            {"scope": entry["scope"], "purpose": entry["purpose"], "provisioned": False}
            if name == "HOP_SYNC_APP_ID"
            else entry
        )
        for name, entry in secrets.items()
        if name in ("HOP_SYNC_APP_ID", "HOP_SYNC_APP_PRIVATE_KEY")
    },
    "provisioned:false with no blocked_on reason",
)

# ...and the workflow reading it must fail fast NAMING it, so the unwired path is never discovered by
# watching an expensive job die at an opaque downstream error. That is the ESP32 defect exactly.
rejects(
    "provisioned:false with no fail-fast step naming it",
    ONLY_KNOWN,
    lambda secrets: {
        name: (
            {**entry, "provisioned": False, "blocked_on": "the App does not exist yet"}
            if name == "HOP_SYNC_APP_ID"
            else entry
        )
        for name, entry in secrets.items()
        if name in ("HOP_SYNC_APP_ID", "HOP_SYNC_APP_PRIVATE_KEY")
    },
    "without a fail-fast step that names it",
)

# The ESP32 App credentials are GONE from the manifest, because the workflow that read them was deleted
# rather than left declaring a credential nobody could provision. A stale entry would now be caught by
# the unused-name check above, but assert it directly so the resolution cannot quietly regress.
assert "HOP_RELEASE_APP_ID" not in declared and "HOP_RELEASE_APP_PRIVATE_KEY" not in declared
assert not (root / ".github/workflows/libhop-esp-release.yml").exists()

# The drift-detector's own credential has to be inventoried, or INFRA-007's failure mode has no name.
assert "BRANCH_PROTECTION_TOKEN" in declared, "the branch-protection audit token is not inventoried"

# Every declared name must be asserted set/unset by the scheduled audit, in a job that can read it.
# Without this, the manifest is only self-consistent and a DELETED secret still reads as provisioned.
guard.check_presence_coverage(root, declared)


def rejects_coverage(label, mutate, fragment):
    work = sandbox()
    try:
        (work / ".github/workflows").mkdir(parents=True, exist_ok=True)
        source = root / ".github/workflows/branch-protection-audit.yml"
        (work / ".github/workflows/branch-protection-audit.yml").write_text(
            mutate(source.read_text(encoding="utf-8")), encoding="utf-8"
        )
        try:
            guard.check_presence_coverage(work, declared)
        except guard.WorkflowSecretsError as error:
            assert fragment in str(error), f"{label}: wrong rejection: {error}"
            return
        raise AssertionError(f"{label}: guard accepted it")
    finally:
        shutil.rmtree(work)


# A declared name with no presence assertion at all: nothing would ever notice its deletion.
rejects_coverage(
    "declared secret with no presence assertion",
    lambda text: text.replace("          BRANCH_PROTECTION_TOKEN: ${{ secrets.BRANCH_PROTECTION_TOKEN != '' }}\n", ""),
    "does not pass BRANCH_PROTECTION_TOKEN",
)

# A whole scope with no presence job.
rejects_coverage(
    "scope with no presence job",
    lambda text: text.replace("--assert-present environment:component-sync", "--assert-present nothing"),
    "runs `--assert-present environment:component-sync`",
)

# A presence job for an environment scope that does not declare the environment cannot read those
# secrets at all, so it would report every one of them unset (or, worse, be tuned to accept that).
rejects_coverage(
    "environment presence job without the environment",
    lambda text: text.replace("    environment:\n      name: component-sync\n", ""),
    "cannot read HOP_SYNC_APP_ID",
)

# And the report itself: names and set/unset only, failing when the live answer contradicts the file.
def presence(label, environ, scopes, expect_error):
    try:
        guard.assert_present(declared, scopes, environ)
    except guard.WorkflowSecretsError as error:
        assert expect_error and expect_error in str(error), f"{label}: wrong rejection: {error}"
        return
    assert not expect_error, f"{label}: guard accepted it"


live = {
    "BOOTSTRAP_TFVARS": "true",
    "BRANCH_PROTECTION_TOKEN": "true",
    "MIRROR_SECRET_AUDIT_TOKEN": "false",
    "RESEND_API_KEY": "true",
    "STRIPE_API_KEY": "true",
    "HOP_SYNC_TOKEN": "true",
}
presence("the live inventory as it stands", live, ["organization", "repository"], None)
# INFRA-007's disarm path: deleting the audit's own token must be a non-green run, not a quiet skip.
presence(
    "deleted BRANCH_PROTECTION_TOKEN",
    {**live, "BRANCH_PROTECTION_TOKEN": "false"},
    ["organization", "repository"],
    "BRANCH_PROTECTION_TOKEN is declared provisioned in repository but is NOT set there",
)
# A provisioned:false to-do that has since been satisfied must force the manifest to be updated.
presence(
    "provisioned:false name that is now set",
    {**live, "MIRROR_SECRET_AUDIT_TOKEN": "true"},
    ["organization", "repository"],
    "clear provisioned:false",
)
# A name the workflow forgot to pass is UNKNOWN, never assumed present.
presence(
    "unmapped name",
    {name: value for name, value in live.items() if name != "STRIPE_API_KEY"},
    ["organization", "repository"],
    "STRIPE_API_KEY was not passed",
)
# And a secret value must never be what gets passed: only the boolean form is accepted.
presence(
    "a value instead of a boolean",
    {**live, "STRIPE_API_KEY": "sk_live_notarealkey"},
    ["organization", "repository"],
    "STRIPE_API_KEY was not passed",
)

print("workflow secrets guard tests passed")
PY
