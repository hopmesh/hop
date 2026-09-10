#!/usr/bin/env python3
"""Guard the hopmesh/monorepo archive boundary.

Enforces that hop contains no non-historical executable, deployment, package
metadata, workflow-dispatch, source checkout, or future trust-authority
references to hopmesh/monorepo.

Historical v0.0.1 and v0.0.2 trust anchors and historical records are permitted
only under an explicit, narrow allowlist where each entry records its reason.
"""

import argparse
import os
import re
import sys
from pathlib import Path

# Explicit, narrow allowlist of files permitted to reference hopmesh/monorepo,
# each with an exact reason justifying its presence.
ALLOWLIST = {
    ".agents/skills/hop-adversarial-audit/SKILL.md": (
        "Historical audit skill description referencing monorepo audits"
    ),
    ".agents/skills/hop-adversarial-audit/evals/trigger-evals.json": (
        "Historical audit evaluation test queries referencing monorepo"
    ),
    ".agents/skills/hop-adversarial-audit/fixtures/sample-ledger.json": (
        "Historical audit sample ledger fixture referencing monorepo remote"
    ),
    ".agents/skills/hop-adversarial-audit/references/finding-schema.md": (
        "Historical audit finding schema example referencing monorepo remote"
    ),
    "docs/audit-history.md": (
        "Historical audit finding referencing hopmesh/monorepo#138"
    ),
    "docs/repo-catalog.md": (
        "Repository catalog documenting repository roles, legacy mirror history, and archive invariant"
    ),
    "docs/release-engineering.md": (
        "Release engineering documentation defining builder authority and archive invariant"
    ),
    "docs/runbooks/incident-response.md": (
        "Historical operational runbook referencing pre-cutover monorepo infrastructure"
    ),
    "docs/runbooks/relay-enable-disable.md": (
        "Historical operational runbook referencing pre-cutover monorepo fleet deployment"
    ),
    "sdk/go/cmd/hop-install/builder_test.go": (
        "Verification tests for v0.0.1/v0.0.2 immutable legacy builder and rejection of legacy builder on post-migration tags"
    ),
    "sdk/go/cmd/hop-install/main.go": (
        "Immutable trust anchor: legacyRepository and legacyBuilder for v0.0.1 and v0.0.2 releases"
    ),
    "tools/CLAUDE.md": (
        "Historical audit note citing PROC-015 and PR #351 copybara export"
    ),
    "tools/copybara/README.md": (
        "Historical documentation of one-time export from old private monorepo"
    ),
    "tools/copybara/auto-export-plan.test.sh": (
        "Test comment documenting historical move of canonical repository from monorepo to hop"
    ),
    "tools/copybara/bootstrap-packages.sh": (
        "Historical setup script comment noting published packages naming monorepo in repository field"
    ),
    "tools/copybara/copy.bara.sky": (
        "Historical comment explaining one-time history replay from old private monorepo"
    ),
    "tools/crates-publish.test.sh": (
        "Test fixture testing handling of legacy repository field in crate metadata"
    ),
    "tools/doc-path-guard.sh": (
        "Guard logic allowing historical PR qualification e.g. hopmesh/monorepo#NUM for PRs above ceiling"
    ),
    "tools/doc-path-guard.test.sh": (
        "Test verifying historical qualified PR citation hopmesh/monorepo#138 passes"
    ),
    "tools/native-artifacts.py": (
        "Historical provenance comment explaining builder moved from hopmesh/monorepo to hopmesh/hop"
    ),
    "tools/native-attestation/create.test.mjs": (
        "Negative security test verifying unauthorized hopmesh/monorepo is rejected in attestation creation"
    ),
    "tools/pages-path-guard.test.sh": (
        "Negative security test verifying rejection when repository is set to hopmesh/monorepo"
    ),
    "tools/release/release.test.sh": (
        "Negative security test verifying release queries do not query archived hopmesh/monorepo"
    ),
    "tools/sync-authority-guard.py": (
        "Negative security assertion requiring that github.com/hopmesh/monorepo is absent from workflow text"
    ),
    "tools/workflow-freshness-guard.py": (
        "Historical provenance comment explaining default repo moved to hopmesh/hop"
    ),
    "tools/workflow-secrets-guard.test.sh": (
        "Negative security test verifying that archived repo hopmesh/monorepo is rejected by repo identity verifier"
    ),
    "tools/archive-readiness-guard.py": (
        "Archive readiness guard scanning and enforcing monorepo archive boundary"
    ),
    "tools/archive-readiness-guard.test.sh": (
        "Self-test for archive readiness guard"
    ),
}

PACKAGE_MANIFEST_NAMES = {
    "package.json",
    "Cargo.toml",
    "shard.yml",
    "mix.exs",
    "pyproject.toml",
}

IGNORED_DIRS = {
    ".git",
    ".claude",
    "target",
    "node_modules",
    "build",
    ".gradle",
    "dist",
}

DOWNLOAD_PATTERN = re.compile(
    r"https?://(?:github\.com/hopmesh/monorepo/releases/download/|raw\.githubusercontent\.com/hopmesh/monorepo/|.*hopmesh/monorepo.*releases/download/)([^\s\'\"\`]+)"
)

WORKFLOW_CHECKOUT_PATTERN = re.compile(
    r"repository:\s*['\"]?hopmesh/monorepo['\"]?"
)

PACKAGE_REPO_PATTERN = re.compile(
    r"(?:\"repository\"|repository|s\.source)\s*[:=]\s*.*hopmesh/monorepo"
)

FUTURE_BUILDER_PATTERN = re.compile(
    r"case\s+([^\n:]*v0\.0\.[3-9][^\n:]*|v[0-9]+\.[1-9][^\n:]*|v[1-9][^\n:]*)\s*:\s*(?:return\s+.*(?:legacyBuilder|legacyRepository|hopmesh/monorepo))"
)


class ArchiveReadinessError(RuntimeError):
    pass


def scan_file_for_violations(rel_path, text):
    errors = []
    lines = text.splitlines()

    # 0. The guard self-test itself contains deliberate test case fixtures
    if rel_path == "tools/archive-readiness-guard.test.sh":
        return []

    # 1. Reject unallowlisted files referencing hopmesh/monorepo
    if "hopmesh/monorepo" in text and rel_path not in ALLOWLIST:
        for lno, line in enumerate(lines, 1):
            if "hopmesh/monorepo" in line:
                errors.append(
                    f"{rel_path}:{lno}: unallowlisted reference to archived repository hopmesh/monorepo"
                )
        return errors

    # 2. Check for invented current or future download URLs
    for lno, line in enumerate(lines, 1):
        for match in DOWNLOAD_PATTERN.finditer(line):
            target = match.group(1)
            # Accept only immutable historical release tags v0.0.1 and v0.0.2
            if not (target.startswith("v0.0.1/") or target.startswith("v0.0.2/")):
                errors.append(
                    f"{rel_path}:{lno}: rejected current download URL pointing to archived hopmesh/monorepo: {match.group(0)}"
                )

    # 3. Check for workflow checkout of archived repository
    is_workflow = (
        rel_path.startswith(".github/workflows/")
        or "/workflows/" in rel_path
        or rel_path.endswith(".workflow.yml")
        or rel_path.endswith(".workflow.yaml")
    )
    for lno, line in enumerate(lines, 1):
        if is_workflow and WORKFLOW_CHECKOUT_PATTERN.search(line):
            errors.append(
                f"{rel_path}:{lno}: rejected workflow source checkout of archived hopmesh/monorepo"
            )

    # 4. Check for package manifest repository field
    filename = Path(rel_path).name
    is_package_manifest = (
        filename in PACKAGE_MANIFEST_NAMES
        or filename.endswith(".podspec")
        or filename.endswith(".gemspec")
    )
    if is_package_manifest:
        for lno, line in enumerate(lines, 1):
            if PACKAGE_REPO_PATTERN.search(line):
                errors.append(
                    f"{rel_path}:{lno}: rejected package manifest repository field pointing to archived hopmesh/monorepo"
                )

    # 5. Check for future-tag builder authorization
    if "sdk/go/cmd/hop-install/" in rel_path or "builder" in rel_path.lower():
        # Check if builderFor maps post-v0.0.2 tag to legacyBuilder
        if FUTURE_BUILDER_PATTERN.search(text):
            errors.append(
                f"{rel_path}: rejected future-tag builder: archived hopmesh/monorepo authorized for post-v0.0.2 release tag"
            )

        # Check for permissive builder set or legacy default
        if "legacyBuilder" in text and "builderFor" in text:
            # Verify builderFor default returns canonical
            if re.search(r"return\s+legacyRepository,\s*legacyBuilder\s*$", text, re.MULTILINE):
                # Verify that this return statement is strictly under v0.0.1 / v0.0.2 case
                for match in re.finditer(r"(case\s+([^:]+):\s*return\s+legacyRepository,\s*legacyBuilder)", text):
                    tags = match.group(2)
                    for tag in tags.split(","):
                        clean_tag = tag.strip().strip('"').strip("'")
                        if clean_tag not in ("v0.0.1", "v0.0.2"):
                            errors.append(
                                f"{rel_path}: rejected future-tag builder: {clean_tag} maps to legacy builder"
                            )

    return errors


def check_repository(root_path):
    root = Path(root_path).resolve()
    all_errors = []
    scanned_count = 0
    monorepo_refs_count = 0

    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in IGNORED_DIRS]
        for filename in filenames:
            file_path = Path(dirpath) / filename
            rel_path = file_path.relative_to(root).as_posix()
            scanned_count += 1
            try:
                text = file_path.read_text(encoding="utf-8", errors="ignore")
            except Exception:
                continue

            if "hopmesh/monorepo" in text:
                monorepo_refs_count += 1

            file_errors = scan_file_for_violations(rel_path, text)
            all_errors.extend(file_errors)

    return all_errors, scanned_count, monorepo_refs_count


def main():
    parser = argparse.ArgumentParser(description="Guard hopmesh/monorepo archive boundary")
    parser.add_argument("--root", default=".", help="Root directory to scan (default: current directory)")
    args = parser.parse_args()

    errors, scanned_count, monorepo_refs_count = check_repository(args.root)
    if errors:
        print(f"::error:: archive-readiness-guard found {len(errors)} violation(s):", file=sys.stderr)
        for err in errors:
            print(f"  {err}", file=sys.stderr)
        sys.exit(1)

    print(
        f"archive-readiness-guard: OK ({scanned_count} files scanned, "
        f"{monorepo_refs_count} allowlisted reference files verified)"
    )


if __name__ == "__main__":
    main()
