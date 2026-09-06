#!/usr/bin/env python3
"""Fail when a mirror's release workflow references a secret nobody ever seeded.

This exists because publishing was broken from the day it was written and nobody could see it. Every
mirror's release.yml mints a GitHub App token to verify canonical-source provenance:

    app-id: ${{ secrets.HOP_SOURCE_APP_ID }}
    private-key: ${{ secrets.HOP_SOURCE_APP_PRIVATE_KEY }}

Neither secret existed on any mirror, at any scope. GitHub resolves an unset secret to the EMPTY
STRING rather than erroring, so the failure surfaced deep inside a third-party action as
"The 'client-id' (or deprecated 'app-id') input must be set to a non-empty string" - a message that
names no secret, no repository, and no fix. Fifteen mirrors were each one unseeded credential away
from being able to publish, with every registry token already in place, and the only symptom was zero
releases.

So: parse what each release workflow REFERENCES and compare it against what is actually seeded, at
every scope GitHub will resolve (repository, the workflow's environment, and organization secrets
visible to that repository). Reporting a secret as missing when an org secret already covers it would
be the same class of blindness in reverse, so all three are checked.

Only secret NAMES are ever read. No value is fetched, printed, or logged; the API does not expose them.

Usage:  python3 tools/release/check-mirror-secrets.py [--json]
Needs a gh token that can read repo/org secret METADATA (admin:org + repo admin).
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path


OWNER = "hopmesh"
SECRET_REF = re.compile(r"secrets\.([A-Z0-9_]+)")
# `environment: <name>` on a job; the release workflows use a single `release` environment.
ENVIRONMENT = re.compile(r"^\s*environment:\s*([A-Za-z0-9_.-]+)\s*$", re.MULTILINE)


class CheckError(RuntimeError):
    pass


def gh_json(path):
    """GET an API path, returning parsed JSON or None when it is absent/forbidden."""
    result = subprocess.run(
        ["gh", "api", path], capture_output=True, text=True, check=False
    )
    if result.returncode != 0:
        return None
    try:
        return json.loads(result.stdout or "null")
    except json.JSONDecodeError:
        return None


def repo_secret_names(repo):
    data = gh_json(f"repos/{OWNER}/{repo}/actions/secrets") or {}
    return {s["name"] for s in data.get("secrets", [])}


def environment_secret_names(repo, environment):
    data = gh_json(f"repos/{OWNER}/{repo}/environments/{environment}/secrets") or {}
    return {s["name"] for s in data.get("secrets", [])}


def org_secret_names_for(repo, cache={}):
    """Org secrets that resolve in `repo`: visibility all/private, or selected including this repo."""
    if "all" not in cache:
        data = gh_json(f"orgs/{OWNER}/actions/secrets") or {}
        cache["all"] = data.get("secrets", [])
    names = set()
    for secret in cache["all"]:
        visibility = secret.get("visibility")
        if visibility in ("all", "private"):
            # `private` means every private org repo. Mirrors are public, so it would NOT resolve
            # there; only count it when the repository is actually private.
            if visibility == "all":
                names.add(secret["name"])
                continue
            info = gh_json(f"repos/{OWNER}/{repo}")
            if info and info.get("private"):
                names.add(secret["name"])
            continue
        if visibility == "selected":
            key = f"selected:{secret['name']}"
            if key not in cache:
                listing = gh_json(
                    f"orgs/{OWNER}/actions/secrets/{secret['name']}/repositories"
                ) or {}
                cache[key] = {r["name"] for r in listing.get("repositories", [])}
            if repo in cache[key]:
                names.add(secret["name"])
    return names

def mirror_branch_protection(repo):
    """Audit default branch protection on the mirror repository (INFRA-019)."""
    data = gh_json(f"repos/{OWNER}/{repo}/branches/main/protection")
    if not data:
        return "main branch is not protected"
    rsc = data.get("required_status_checks")
    if not rsc:
        return "main branch lacks required status checks"
    admins = data.get("enforce_admins", {}).get("enabled")
    if admins is not True:
        return "main branch does not enforce admin parity (enforce_admins is not true)"
    return None


def mirror_environment_protection(repo, environment):
    """Audit environment protection rules on the mirror release environment (INFRA-019)."""
    data = gh_json(f"repos/{OWNER}/{repo}/environments/{environment}")
    if not data:
        return f"environment '{environment}' is not configured"
    rules = data.get("protection_rules", [])
    has_reviewer = False
    for r in rules:
        for rev in r.get("reviewers", []):
            if rev.get("reviewer", {}).get("login") == "jwaldrip":
                has_reviewer = True
    if not has_reviewer:
        return f"environment '{environment}' lacks required reviewer 'jwaldrip'"
    policy = data.get("deployment_branch_policy")
    if not policy:
        return f"environment '{environment}' lacks deployment_branch_policy"
    return None


def canonical_app_installation():
    """Verify hop-source GitHub App is installed on hopmesh/hop (INFRA-023)."""
    data = gh_json(f"repos/{OWNER}/hop/installation")
    if not data:
        return "hop-source GitHub App is not installed on hopmesh/hop"
    perms = data.get("permissions", {})
    missing_perms = [
        f"{req}:read"
        for req in ("actions", "checks", "contents")
        if perms.get(req) not in ("read", "write", "admin")
    ]
    if missing_perms:
        return f"hop-source GitHub App on hopmesh/hop missing permissions: {', '.join(missing_perms)}"
    return None


def workflow_requirements(root):
    """Every publishing component: the secrets its release.yml references + its environment."""
    components = json.loads(
        (root / "tools/copybara/components.json").read_text(encoding="utf-8")
    )
    out = []
    for name, entry in sorted(components.items()):
        workflow = root / entry["prefix"] / ".github/workflows/release.yml"
        if not workflow.is_file():
            continue
        text = workflow.read_text(encoding="utf-8")
        environments = sorted(set(ENVIRONMENT.findall(text)))
        out.append(
            {
                "component": name,
                "required": sorted(set(SECRET_REF.findall(text))),
                "environments": environments,
            }
        )
    if not out:
        raise CheckError("no publishing components found")
    return out


def audit(root, check_protection=False):
    findings = []
    for entry in workflow_requirements(root):
        repo = entry["component"]
        seeded = repo_secret_names(repo) | org_secret_names_for(repo)
        for environment in entry["environments"]:
            seeded |= environment_secret_names(repo, environment)
        missing = [name for name in entry["required"] if name not in seeded]

        protection_issues = []
        if check_protection:
            bp_issue = mirror_branch_protection(repo)
            if bp_issue:
                protection_issues.append(bp_issue)
            for env in entry["environments"]:
                env_issue = mirror_environment_protection(repo, env)
                if env_issue:
                    protection_issues.append(env_issue)

        findings.append({**entry, "missing": missing, "protection_issues": protection_issues})
    return findings


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--root", default=".")
    parser.add_argument("--audit-protection", action="store_true", help="also audit mirror branch and environment protection rules")
    args = parser.parse_args()

    findings = audit(Path(args.root).resolve(), check_protection=args.audit_protection)
    app_issue = canonical_app_installation() if args.audit_protection else None
    if args.json:
        payload = {"mirrors": findings}
        if args.audit_protection:
            payload["app_installation"] = app_issue or "OK"
        print(json.dumps(payload, indent=2))
    else:
        for entry in findings:
            status_parts = []
            if entry["missing"]:
                status_parts.append("MISSING " + ", ".join(entry["missing"]))
            if entry.get("protection_issues"):
                status_parts.append("PROTECTION: " + ", ".join(entry["protection_issues"]))
            state = "; ".join(status_parts) if status_parts else "OK"
            print(f"{entry['component']:22} {state}")
        if args.audit_protection:
            print(f"{'hop-source App (hop)':22} {'OK' if not app_issue else app_issue}")

    broken = [entry for entry in findings if entry["missing"]]
    prot_broken = [entry for entry in findings if entry.get("protection_issues")]
    if broken or prot_broken or app_issue:
        if broken:
            names = sorted({name for entry in broken for name in entry["missing"]})
            print(
                f"\n{len(broken)} of {len(findings)} publishing mirrors cannot release: "
                f"unseeded {', '.join(names)}.\n"
                "An unset secret resolves to the empty string, so the release fails inside "
                "create-github-app-token instead of naming the cause. Seed it once as an organization "
                "secret scoped to these repositories (see docs/release-engineering.md, which carries the "
                "exact gh secret set commands).",
                file=sys.stderr,
            )
        if prot_broken:
            print(
                f"\n{len(prot_broken)} of {len(findings)} publishing mirrors have unprotected release boundaries (INFRA-019).",
                file=sys.stderr,
            )
        if app_issue:
            print(f"\n{app_issue} (INFRA-023).", file=sys.stderr)
        raise SystemExit(1)
    print(f"\nall {len(findings)} publishing mirrors have every referenced secret seeded and protection rules satisfied")

if __name__ == "__main__":
    try:
        main()
    except (CheckError, OSError, ValueError, KeyError) as error:
        raise SystemExit(f"mirror secret check failed: {error}") from error
