#!/usr/bin/env python3
"""Guard the hopmesh/monorepo archive boundary.

Enforces that hop contains no non-historical executable, deployment, package
metadata, workflow-dispatch, source checkout, or future trust-authority
references to hopmesh/monorepo.

Historical v0.0.1 and v0.0.2 trust anchors, negative security checks, and
historical records are permitted only under an explicit, narrow allowlist
where every entry enforces an explicit line-level pattern class predicate.
Prohibited executable patterns are evaluated first with case-insensitive
matching and reject unconditionally even in allowlisted files.
"""

import argparse
import os
import re
import sys
from pathlib import Path

# Explicit, narrow allowlist of files permitted to reference hopmesh/monorepo,
# with each entry recording its reason and its specific allowed pattern class.
ALLOWLIST = {
    # Operational runbooks (strictly narrowed to blocked handoffs or dated history)
    "docs/runbooks/incident-response.md": {
        "reason": "Operational runbook with explicit blocked handoff and dated historical context",
        "pattern_class": "runbook_blocked_or_historical",
    },
    "docs/runbooks/relay-enable-disable.md": {
        "reason": "Operational runbook with explicit blocked handoff and dated historical context",
        "pattern_class": "runbook_blocked_or_historical",
    },
    # Immutable Go installer release trust anchors
    "sdk/go/cmd/hop-install/main.go": {
        "reason": "Immutable trust anchor: legacyRepository and legacyBuilder for v0.0.1 and v0.0.2 releases",
        "pattern_class": "go_legacy_builder_v001_v002",
    },
    "sdk/go/cmd/hop-install/builder_test.go": {
        "reason": "Verification tests for v0.0.1/v0.0.2 immutable legacy builder and rejection of legacy builder on post-migration tags",
        "pattern_class": "go_builder_test",
    },
    # Catalog and release docs
    "docs/repo-catalog.md": {
        "reason": "Repository catalog documenting repository roles, legacy mirror history, and archive invariant",
        "pattern_class": "catalog_doc",
    },
    "docs/release-engineering.md": {
        "reason": "Release engineering documentation defining builder authority and archive invariant",
        "pattern_class": "release_doc",
    },
    # Historical audit documentation and fixtures
    "docs/audit-history.md": {
        "reason": "Historical audit finding referencing hopmesh/monorepo#138",
        "pattern_class": "audit_record",
    },
    ".agents/skills/hop-adversarial-audit/SKILL.md": {
        "reason": "Historical audit skill description referencing monorepo audits",
        "pattern_class": "audit_record",
    },
    ".agents/skills/hop-adversarial-audit/evals/trigger-evals.json": {
        "reason": "Historical audit evaluation test queries referencing monorepo",
        "pattern_class": "audit_record",
    },
    ".agents/skills/hop-adversarial-audit/fixtures/sample-ledger.json": {
        "reason": "Historical audit sample ledger fixture referencing monorepo remote",
        "pattern_class": "audit_record",
    },
    ".agents/skills/hop-adversarial-audit/references/finding-schema.md": {
        "reason": "Historical audit finding schema example referencing monorepo remote",
        "pattern_class": "audit_record",
    },
    # Historical tool documentation and setup
    "tools/CLAUDE.md": {
        "reason": "Historical audit note citing PROC-015 and PR #351 copybara export",
        "pattern_class": "historical_doc",
    },
    "tools/copybara/README.md": {
        "reason": "Historical documentation of one-time export from old private monorepo",
        "pattern_class": "historical_doc",
    },
    "tools/copybara/copy.bara.sky": {
        "reason": "Historical comment explaining one-time history replay from old private monorepo",
        "pattern_class": "historical_doc",
    },
    "tools/copybara/bootstrap-packages.sh": {
        "reason": "Historical setup script comment noting published packages naming monorepo in repository field",
        "pattern_class": "historical_doc",
    },
    "tools/copybara/auto-export-plan.test.sh": {
        "reason": "Test comment documenting historical move of canonical repository from monorepo to hop",
        "pattern_class": "historical_doc",
    },
    "tools/native-artifacts.py": {
        "reason": "Historical provenance comment explaining builder moved from hopmesh/monorepo to hopmesh/hop",
        "pattern_class": "historical_doc",
    },
    "tools/workflow-freshness-guard.py": {
        "reason": "Historical provenance comment explaining default repo moved to hopmesh/hop",
        "pattern_class": "historical_doc",
    },
    # Negative security assertions and verification tests
    "tools/sync-authority-guard.py": {
        "reason": "Negative security assertion requiring that github.com/hopmesh/monorepo is absent from workflow text",
        "pattern_class": "negative_security_assertion",
    },
    "tools/workflow-secrets-guard.test.sh": {
        "reason": "Negative security test verifying that archived repo hopmesh/monorepo is rejected by repo identity verifier",
        "pattern_class": "negative_security_test",
    },
    "tools/native-attestation/create.test.mjs": {
        "reason": "Negative security test verifying unauthorized hopmesh/monorepo is rejected in attestation creation",
        "pattern_class": "negative_security_test",
    },
    "tools/pages-path-guard.test.sh": {
        "reason": "Negative security test verifying rejection when repository is set to hopmesh/monorepo",
        "pattern_class": "negative_security_test",
    },
    "tools/release/release.test.sh": {
        "reason": "Negative security test verifying release queries do not query archived hopmesh/monorepo",
        "pattern_class": "negative_security_test",
    },
    "tools/crates-publish.test.sh": {
        "reason": "Test fixture testing handling of legacy repository field in crate metadata",
        "pattern_class": "negative_security_test",
    },
    "tools/doc-path-guard.sh": {
        "reason": "Guard logic allowing historical PR qualification e.g. hopmesh/monorepo#NUM for PRs above ceiling",
        "pattern_class": "doc_path_guard",
    },
    "tools/doc-path-guard.test.sh": {
        "reason": "Test verifying historical qualified PR citation hopmesh/monorepo#138 passes",
        "pattern_class": "doc_path_guard",
    },
    "tools/archive-readiness-guard.py": {
        "reason": "Archive readiness guard scanning and enforcing monorepo archive boundary",
        "pattern_class": "guard_itself",
    },
    "tools/archive-readiness-guard.test.sh": {
        "reason": "Self-test for archive readiness guard",
        "pattern_class": "guard_itself",
    },
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
    "__pycache__",
}

# Priority 1: Prohibited executable patterns evaluated first with case-insensitivity.
# These reject unconditionally across all files, even if a safety phrase appears on the same line.
PROHIBITED_EXECUTABLE_PATTERNS = [
    (
        re.compile(r"(?i)\b(?:git|gh\s+repo)\s+clone\s+.*hopmesh/monorepo"),
        "rejected executable clone of archived hopmesh/monorepo",
    ),
    (
        re.compile(r"(?i)\bgit\s+(?:checkout|fetch|pull)\s+.*hopmesh/monorepo"),
        "rejected executable git operation on archived hopmesh/monorepo",
    ),
    (
        re.compile(r"(?i)\brepository:\s*['\"]?hopmesh/monorepo['\"]?"),
        "rejected workflow source checkout of archived hopmesh/monorepo",
    ),
    (
        re.compile(r"(?i)\buses:\s*actions/checkout@.*hopmesh/monorepo"),
        "rejected workflow source checkout of archived hopmesh/monorepo",
    ),
    (
        re.compile(r"(?i)\bgit\s+push\s+.*hopmesh/monorepo"),
        "rejected push to archived hopmesh/monorepo",
    ),
    (
        re.compile(r"(?i)\bgh\s+api\s+/repos/hopmesh/monorepo"),
        "rejected active api call targeting archived hopmesh/monorepo",
    ),
    (
        re.compile(r"(?i)\bgh\s+(?:variable|secret|workflow)\s+.*hopmesh/monorepo"),
        "rejected active gh cli command targeting archived hopmesh/monorepo",
    ),
    (
        re.compile(r"(?i)\bIn\s+`?hopmesh/monorepo`?,\s*(?:verify|set|check|add)"),
        "rejected active operational instruction targeting archived hopmesh/monorepo",
    ),
    (
        re.compile(r"(?i)\bIn\s+`?hopmesh/monorepo`?\s+Settings"),
        "rejected active operational instruction targeting archived hopmesh/monorepo",
    ),
    (
        re.compile(r"(?i)\bto\s+`?main`?\s+in\s+`?hopmesh/monorepo`?"),
        "rejected active operational instruction targeting archived hopmesh/monorepo",
    ),
    (
        re.compile(r"(?i)\b(?:push|re-run|trigger|revert)\s+.*in\s+`?hopmesh/monorepo`?"),
        "rejected active operational instruction targeting archived hopmesh/monorepo",
    ),
    (
        re.compile(r"(?i)hopmesh/monorepo/\.github/workflows/"),
        "rejected workflow reference in archived hopmesh/monorepo",
    ),
    (
        re.compile(r"(?i)hopmesh/monorepo/infra/"),
        "rejected infra reference in archived hopmesh/monorepo",
    ),
]

DOWNLOAD_PATTERN = re.compile(
    r"(?i)https?://(?:github\.com/hopmesh/monorepo/releases/download/|raw\.githubusercontent\.com/hopmesh/monorepo/|.*hopmesh/monorepo.*releases/download/)([^\s\'\"\`]+)"
)

PACKAGE_REPO_PATTERN = re.compile(
    r"(?i)(?:\"repository\"|repository|s\.source)\s*[:=]\s*.*hopmesh/monorepo"
)

FUTURE_BUILDER_PATTERN = re.compile(
    r"(?i)case\s+([^\n:]*v0\.0\.[3-9][^\n:]*|v[0-9]+\.[1-9][^\n:]*|v[1-9][^\n:]*)\s*:\s*(?:return\s+.*(?:legacyBuilder|legacyRepository|hopmesh/monorepo))"
)

RUNBOOK_PERMITTED_PATTERNS = [
    re.compile(r"(?i)archived\s+and\s+no\s+operational\s+action\s+may\s+target\s+it"),
    re.compile(r"(?i)no\s+.*may\s+target\s+(?:archived\s+)?`?hopmesh/monorepo`?"),
    re.compile(r"(?i)no\s+deployment\s+may\s+run\s+from\s+`?hopmesh/monorepo`?"),
    re.compile(r"(?i)do\s+not\s+target\s+(?:archived\s+)?`?hopmesh/monorepo`?"),
    re.compile(r"(?i)zero\s+deployment\s+authority"),
    re.compile(r"(?i)prior\s+to\s+the\s+2026-09\s+cutover"),
    re.compile(r"(?i)historical\s+context"),
    re.compile(r"(?i)historically\s+resided"),
]


def check_class_predicate(rel_path, pattern_class, line_str):
    """Enforce explicit line-level predicate semantics for every allowlisted class."""
    if pattern_class == "guard_itself":
        return True

    if pattern_class == "runbook_blocked_or_historical":
        return any(p.search(line_str) for p in RUNBOOK_PERMITTED_PATTERNS)

    if pattern_class == "historical_doc":
        if rel_path.endswith(".md"):
            return True
        return line_str.startswith(("#", "//", "/*", "*", "--", "- "))

    if pattern_class == "go_legacy_builder_v001_v002":
        return any(
            x in line_str
            for x in [
                "legacyRepository",
                "legacyBuilder",
                'case "v0.0.1", "v0.0.2":',
                "// The canonical source moved: hopmesh/monorepo was archived",
            ]
        )

    if pattern_class == "go_builder_test":
        return any(
            x in line_str
            for x in [
                "legacyRepository",
                "legacyBuilder",
                "The canonical builder moved when hopmesh/monorepo was archived",
                "TestValidateManifestRejectsCrossEraBuilder",
            ]
        )

    if pattern_class == "negative_security_assertion":
        return "not in text" in line_str or "hopmesh/monorepo is the archived one" in line_str

    if pattern_class == "negative_security_test":
        return any(
            x in line_str
            for x in [
                "verify_repo_identity",
                "archived",
                "GITHUB_REPOSITORY",
                "repository",
                "startswith",
                "= hopmesh/monorepo",
            ]
        )

    if pattern_class == "doc_path_guard":
        return bool(re.search(r"(?i)hopmesh/monorepo", line_str)) and (
            line_str.startswith("#")
            or "re.search" in line_str
            or "hopmesh/monorepo#138" in line_str
            or "qualify with repository" in line_str
        )

    if pattern_class == "audit_record":
        return any(
            x in line_str
            for x in [
                "hopmesh/monorepo#138",
                "Review PR 241 in hopmesh/monorepo",
                "git@github.com:hopmesh/monorepo.git",
                "red-team review of hopmesh/monorepo",
                "Always use for a HOP or hopmesh/monorepo audit",
            ]
        )

    if pattern_class in ("catalog_doc", "release_doc"):
        return True

    return False


def scan_file_for_violations(rel_path, text):
    errors = []
    lines = text.splitlines()

    # The guard and its self-test contain the pattern definitions and test fixtures
    if rel_path in ("tools/archive-readiness-guard.py", "tools/archive-readiness-guard.test.sh"):
        return []

    # Priority 1: Unconditional prohibited executable pattern checks
    for lno, line in enumerate(lines, 1):
        if not re.search(r"(?i)hopmesh/monorepo", line):
            continue
        for pattern, msg in PROHIBITED_EXECUTABLE_PATTERNS:
            if pattern.search(line):
                errors.append(f"{rel_path}:{lno}: {msg}: {line.strip()}")
                break

    # Priority 1.1: Download URL pattern checks
    for lno, line in enumerate(lines, 1):
        for match in DOWNLOAD_PATTERN.finditer(line):
            target = match.group(1)
            # Accept only immutable historical release tags v0.0.1 and v0.0.2
            if not (target.startswith("v0.0.1/") or target.startswith("v0.0.2/")):
                errors.append(
                    f"{rel_path}:{lno}: rejected current download URL pointing to archived hopmesh/monorepo: {match.group(0)}"
                )

    # Priority 1.2: Package manifest repository fields
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
                    f"{rel_path}:{lno}: rejected package manifest repository field pointing to archived hopmesh/monorepo: {line.strip()}"
                )

    # Priority 1.3: Future-tag builder authorization
    if "sdk/go/cmd/hop-install/" in rel_path or "builder" in rel_path.lower():
        if FUTURE_BUILDER_PATTERN.search(text):
            errors.append(
                f"{rel_path}: rejected future-tag builder: archived hopmesh/monorepo authorized for post-v0.0.2 release tag"
            )
        if "legacyBuilder" in text and "builderFor" in text:
            if re.search(r"return\s+legacyRepository,\s*legacyBuilder\s*$", text, re.MULTILINE):
                for match in re.finditer(
                    r"(case\s+([^:]+):\s*return\s+legacyRepository,\s*legacyBuilder)", text
                ):
                    tags = match.group(2)
                    for tag in tags.split(","):
                        clean_tag = tag.strip().strip('"').strip("'")
                        if clean_tag not in ("v0.0.1", "v0.0.2"):
                            errors.append(
                                f"{rel_path}: rejected future-tag builder: {clean_tag} maps to legacy builder"
                            )

    # Priority 2: If the file is NOT on the allowlist, reject any reference
    if re.search(r"(?i)hopmesh/monorepo", text) and rel_path not in ALLOWLIST:
        for lno, line in enumerate(lines, 1):
            if re.search(r"(?i)hopmesh/monorepo", line) and not any(
                e.startswith(f"{rel_path}:{lno}:") for e in errors
            ):
                errors.append(
                    f"{rel_path}:{lno}: unallowlisted reference to archived repository hopmesh/monorepo"
                )
        return errors

    # Priority 3: For allowlisted files, enforce pattern class predicates for each line
    if rel_path in ALLOWLIST:
        config = ALLOWLIST[rel_path]
        pattern_class = config.get("pattern_class")
        for lno, line in enumerate(lines, 1):
            if not re.search(r"(?i)hopmesh/monorepo", line):
                continue
            # If this line already produced an executable error, do not double-report
            if any(e.startswith(f"{rel_path}:{lno}:") for e in errors):
                continue
            if not check_class_predicate(rel_path, pattern_class, line):
                errors.append(
                    f"{rel_path}:{lno}: line failed pattern class predicate '{pattern_class}': {line.strip()}"
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

            if re.search(r"(?i)hopmesh/monorepo", text):
                monorepo_refs_count += 1

            file_errors = scan_file_for_violations(rel_path, text)
            all_errors.extend(file_errors)

    return all_errors, scanned_count, monorepo_refs_count


def main():
    parser = argparse.ArgumentParser(description="Guard hopmesh/monorepo archive boundary")
    parser.add_argument(
        "--root", default=".", help="Root directory to scan (default: current directory)"
    )
    args = parser.parse_args()

    errors, scanned_count, monorepo_refs_count = check_repository(args.root)
    if errors:
        print(
            f"::error:: archive-readiness-guard found {len(errors)} violation(s):",
            file=sys.stderr,
        )
        for err in errors:
            print(f"  {err}", file=sys.stderr)
        sys.exit(1)

    print(
        f"archive-readiness-guard: OK ({scanned_count} files scanned, "
        f"{monorepo_refs_count} allowlisted reference files verified)"
    )


if __name__ == "__main__":
    main()
