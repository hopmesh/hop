#!/usr/bin/env python3
"""Every `secrets.NAME` a workflow reads must be provisioned in a scope that job can actually read.

A workflow that reads an unprovisioned secret name does not fail loudly, it fails obscurely: the step
using it errors with whatever the consuming action says about an empty input, long after the expensive
jobs ahead of it have run, and nothing in the repo says the path was never wired at all. That is how
libhop-esp-release.yml shipped referencing HOP_RELEASE_APP_ID and HOP_RELEASE_APP_PRIVATE_KEY, two
names set in NO scope (not org, not repo, not the `release` environment), so from the commit that
introduced them (4d5344a) its publish job could never complete. It has since been deleted; see
docs/release-engineering.md, which also records that the EARLIER form of that workflow, using the org
HOP_SYNC_TOKEN, did publish v0.0.1 to hopmesh/libhop, a repo since RETIRED with the mirror fleet.

Detection here is STATIC and always runs: tools/workflow-secrets.json declares the one scope each name
lives in, this guard asserts the workflows and that file agree in both directions, and, for an
environment-scoped name, that every job reading it declares that environment. A name nobody
provisioned therefore has to be added to the manifest to pass, which is where its absence is visible.

The static half cannot tell you a secret was DELETED, only that the manifest and the workflows agree.
Two modes close that, and one of them runs on a schedule:

  --assert-present <scope>...  Compares the manifest against what a real job can actually read, from
      inside a job in that scope: the workflow passes `${{ secrets.NAME != '' }}` (a boolean, never the
      value) as an env var per declared name, and this reports each NAME as set or unset and fails when
      that contradicts the manifest. branch-protection-audit.yml runs it weekly, one job per scope, and
      check_static() requires every declared name to be covered there, so a secret cannot be added to
      the manifest without something asserting it exists. This needs NO credential, which is why it is
      the automated half.

  --verify-live  The operator check: reads the org, repository and environment inventories through the
      API. It needs a token with admin:org plus secrets read, which this repo does not have provisioned,
      so NO workflow runs it. Run it by hand when you have such a token.

Both print NAMES and set/unset only. Secret VALUES are never read, printed, or logged: --verify-live
asks the API, which does not return them, and --assert-present sees only a boolean.
"""

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path


REPOSITORY = "hopmesh/hop"
ORGANIZATION = "hopmesh"
# The workflow that asserts, on a schedule, that every declared name is really provisioned.
PRESENCE_WORKFLOW = ".github/workflows/branch-protection-audit.yml"
PRESENCE_FLAG = "--assert-present"
# Issued by the runner for every job. It is not provisioned by anyone and has no scope to declare.
RUNNER_TOKEN = "GITHUB_TOKEN"
# Only a real expression reference counts. A bare "secrets.json" in a comment is prose, not a read.
EXPRESSION = re.compile(r"\$\{\{(.*?)\}\}", re.S)
SECRET_REFERENCE = re.compile(r"\bsecrets\.([A-Za-z_][A-Za-z0-9_]*)")


def secret_names(text):
    names = set()
    for expression in EXPRESSION.findall(text):
        names.update(SECRET_REFERENCE.findall(expression))
    return names


class WorkflowSecretsError(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise WorkflowSecretsError(message)


def jobs(text):
    """Split a workflow's `jobs:` mapping into (id, body) pairs, by two-space indentation."""
    match = re.search(r"(?ms)^jobs:\n(.*)\Z", text)
    if match is None:
        return []
    return [
        (job.group(1), job.group(2))
        for job in re.finditer(
            r"(?ms)^  ([A-Za-z0-9_-]+):\n(.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)", match.group(1)
        )
    ]


def job_environment(body):
    """The environment a job declares, in either the inline or the `name:` form."""
    inline = re.search(r"^    environment:\s*([A-Za-z0-9_.-]+)\s*$", body, re.MULTILINE)
    if inline:
        return inline.group(1)
    block = re.search(r"^    environment:\s*\n\s+name:\s*([A-Za-z0-9_.-]+)\s*$", body, re.MULTILINE)
    return block.group(1) if block else None


def references(root):
    """{name: [(workflow, job id, declared environment)]} for every secret a workflow reads."""
    found = {}
    for workflow in sorted((Path(root) / ".github/workflows").glob("*.yml")):
        text = workflow.read_text(encoding="utf-8")
        for job_id, body in jobs(text):
            environment = job_environment(body)
            for name in sorted(secret_names(body)):
                if name == RUNNER_TOKEN:
                    continue
                found.setdefault(name, []).append((workflow.name, job_id, environment))
    return found


def check_static(root):
    root = Path(root)
    manifest = json.loads((root / "tools/workflow-secrets.json").read_text(encoding="utf-8"))
    declared = manifest["secrets"]
    used = references(root)

    unknown = sorted(set(used) - set(declared))
    require(
        not unknown,
        "workflow reads secret names that no scope is declared for: "
        + ", ".join(f"{name} ({used[name][0][0]})" for name in unknown),
    )
    stale = sorted(set(declared) - set(used))
    require(not stale, "tools/workflow-secrets.json declares unused secret names: " + ", ".join(stale))

    for name, entry in sorted(declared.items()):
        scope = entry["scope"]
        require(
            scope in ("organization", "repository") or scope.startswith("environment:"),
            f"{name}: unknown scope {scope!r}",
        )
        if entry.get("provisioned", True) is False:
            # A declared-but-unset name is allowed to exist (some paths are genuinely waiting on a
            # credential that only an owner can create), but it must say why, and every workflow that
            # reads it must fail FAST and NAME it, so the path is never discovered by watching an
            # expensive job die at a downstream action with an opaque error.
            require(entry.get("blocked_on"), f"{name}: provisioned:false with no blocked_on reason")
            for workflow, job_id, _ in used[name]:
                text = (Path(root) / ".github/workflows" / workflow).read_text(encoding="utf-8")
                require(
                    re.search(rf"::error [^\n]*{re.escape(name)}", text)
                    or re.search(rf'missing="\$missing {re.escape(name)}"', text),
                    f"{workflow} reads {name}, which is provisioned nowhere, without a fail-fast "
                    "step that names it",
                )
        if not scope.startswith("environment:"):
            continue
        environment = scope.split(":", 1)[1]
        for workflow, job_id, declared_environment in used[name]:
            require(
                declared_environment == environment,
                f"{workflow} job `{job_id}` reads {name}, which is provisioned only in the "
                f"{environment} environment, but the job declares "
                + (f"environment {declared_environment}" if declared_environment else "no environment"),
            )
    for name in sorted(used):
        entry = declared[name]
        state = "declared" if entry.get("provisioned", True) else "declared-NOT-PROVISIONED"
        print(f"{name}={state}({entry['scope']})")
    return declared


def presence_expression(name):
    """The ONLY form allowed: a boolean, so the workflow never puts a secret value in an env var."""
    return "${{ secrets.%s != '' }}" % name


def presence_assertions(text):
    """{scope: (job id, declared environment, job body)} for each --assert-present job."""
    found = {}
    for job_id, body in jobs(text):
        for match in re.finditer(rf"{re.escape(PRESENCE_FLAG)}([A-Za-z0-9:._ -]*)", body):
            for scope in match.group(1).split():
                found[scope] = (job_id, job_environment(body), body)
    return found


def check_presence_coverage(root, declared):
    """Every declared name must be asserted set/unset by a scheduled job that can actually read it.

    Without this, the manifest is only self-consistent: it would still say a name is provisioned long
    after the secret was deleted, which is precisely how a disarmed control keeps reporting green.
    """
    workflow = Path(root) / PRESENCE_WORKFLOW
    require(workflow.is_file(), f"{PRESENCE_WORKFLOW} is missing, so nothing asserts these names exist")
    text = workflow.read_text(encoding="utf-8")
    assertions = presence_assertions(text)
    for name, entry in sorted(declared.items()):
        scope = entry["scope"]
        require(
            scope in assertions,
            f"{name}: no job in {PRESENCE_WORKFLOW} runs `{PRESENCE_FLAG} {scope}`, so nothing "
            "ever checks that this scope is still provisioned",
        )
        job_id, environment, body = assertions[scope]
        if scope.startswith("environment:"):
            wanted = scope.split(":", 1)[1]
            require(
                environment == wanted,
                f"{PRESENCE_WORKFLOW} job `{job_id}` asserts the {scope} scope but declares "
                + (f"environment {environment}" if environment else "no environment")
                + f", so it cannot read {name} at all",
            )
        require(
            presence_expression(name) in body,
            f"{PRESENCE_WORKFLOW} job `{job_id}` does not pass {name} as "
            f"`{presence_expression(name)}`, so its presence is never asserted",
        )


def assert_present(declared, scopes, environ):
    """Report each declared name in `scopes` as set or unset, from inside a job in that scope."""
    require(scopes, f"{PRESENCE_FLAG} needs at least one scope")
    checked = []
    problems = []
    for name, entry in sorted(declared.items()):
        if entry["scope"] not in scopes:
            continue
        checked.append(name)
        raw = environ.get(name)
        if raw not in ("true", "false"):
            problems.append(
                f"{name} was not passed as `{presence_expression(name)}`, so its presence is unknown"
            )
            print(f"{name}=UNKNOWN ({entry['scope']})")
            continue
        present = raw == "true"
        expected = entry.get("provisioned", True)
        print(f"{name}={'set' if present else 'unset'} ({entry['scope']})")
        if not present and expected:
            problems.append(f"{name} is declared provisioned in {entry['scope']} but is NOT set there")
        elif present and not expected:
            problems.append(
                f"{name} is set now; clear provisioned:false for it in tools/workflow-secrets.json"
            )
    require(checked, "no declared secret has any of the scopes " + ", ".join(scopes))
    require(not problems, "; ".join(problems))


def verify_repo_identity(repo):
    """Verify the target repository is canonical and active before auditing secrets."""
    result = subprocess.run(
        ["gh", "api", f"repos/{repo}", "--jq", "{full_name: .full_name, id: .id, archived: .archived}"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise WorkflowSecretsError(f"cannot verify repository identity at repos/{repo}")
    import json
    try:
        data = json.loads(result.stdout)
    except Exception as exc:
        raise WorkflowSecretsError(f"cannot parse repository identity from repos/{repo}: {exc}")
    if data.get("full_name") != REPOSITORY or data.get("archived") is True:
        raise WorkflowSecretsError(f"repository {repo} is not canonical hopmesh/hop or is archived")
    if not isinstance(data.get("id"), int) or data.get("id") <= 0:
        raise WorkflowSecretsError(f"repository {repo} has invalid ID")


def _inventory(path):
    result = subprocess.run(
        ["gh", "api", path, "--jq", ".secrets[].name"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise WorkflowSecretsError(f"cannot read the secret inventory at {path}")
    return {line.strip() for line in result.stdout.splitlines() if line.strip()}


def check_live(declared):
    """Assert each declared name is set in exactly the scope claimed. Names only, never values."""
    verify_repo_identity(REPOSITORY)
    scopes = {"organization": _inventory(f"orgs/{ORGANIZATION}/actions/secrets")}
    scopes["repository"] = _inventory(f"repos/{REPOSITORY}/actions/secrets")
    for entry in declared.values():
        scope = entry["scope"]
        if scope.startswith("environment:") and scope not in scopes:
            environment = scope.split(":", 1)[1]
            scopes[scope] = _inventory(f"repos/{REPOSITORY}/environments/{environment}/secrets")
    missing = []
    for name, entry in sorted(declared.items()):
        present = name in scopes[entry["scope"]]
        expected = entry.get("provisioned", True)
        print(f"{name}={'set' if present else 'unset'} ({entry['scope']})")
        if not present:
            missing.append(f"{name} ({entry['scope']})")
        elif not expected:
            missing.append(f"{name} is now set; clear provisioned:false in tools/workflow-secrets.json")
    require(not missing, "declared secrets do not match their scope: " + ", ".join(missing))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--verify-live", action="store_true")
    parser.add_argument(
        PRESENCE_FLAG,
        nargs="+",
        default=[],
        metavar="SCOPE",
        help="assert the declared names in these scopes are set, from inside a job in that scope",
    )
    parser.add_argument("--root", default=str(Path(__file__).resolve().parent.parent))
    args = parser.parse_args()
    try:
        declared = check_static(args.root)
        check_presence_coverage(args.root, declared)
        if args.assert_present:
            assert_present(declared, args.assert_present, os.environ)
        if args.verify_live:
            check_live(declared)
    except (WorkflowSecretsError, KeyError, ValueError) as error:
        print(f"::error::workflow secrets: {error}")
        return 1
    print("workflow secrets OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
