#!/usr/bin/env python3
"""Guard the hopmesh/monorepo archive boundary.

Enforces that hop contains no non-historical executable, deployment, package
metadata, workflow-dispatch, source checkout, or future trust-authority
references to hopmesh/monorepo.

Active tool, code, and test files enforce exact occurrence allowlists keyed to
anchored line regular expressions and maximum occurrence counts. Prohibited
executable patterns (including subprocess list forms, shell array syntax, split
quoting, and mixed-case identifiers) are evaluated first and reject
unconditionally across all files.
"""

import argparse
import os
import re
import sys
from pathlib import Path

# Exact occurrence allowlist for active code, test, and tool files.
# Every active file is pinned to its exact permitted line regular expressions
# and exact occurrence count. Any additional or altered occurrence fails.
ACTIVE_FILE_EXACT_ALLOWLIST = {
    "sdk/go/cmd/hop-install/main.go": [
        re.compile(r"^// The canonical source moved: hopmesh/monorepo was archived and hopmesh/hop became the public$"),
        re.compile(r'^legacyRepository\s*=\s*"https://github\.com/hopmesh/monorepo"$'),
        re.compile(r'^legacyBuilder\s*=\s*"hopmesh/monorepo"$'),
    ],
    "sdk/go/cmd/hop-install/builder_test.go": [
        re.compile(r"^// The canonical builder moved when hopmesh/monorepo was archived and hopmesh/hop became the source\.$"),
    ],
    "tools/native-artifacts.py": [
        re.compile(r"^# The builder moved to hopmesh/hop when hopmesh/monorepo was archived\. This module only ever$"),
    ],
    "tools/workflow-freshness-guard.py": [
        re.compile(r"^# now; hopmesh/monorepo was archived, so the old default would have queried a repo whose Actions are$"),
    ],
    "tools/sync-authority-guard.py": [
        re.compile(r"^# dead URL\. hop is now the canonical public source and hopmesh/monorepo is the archived one, so the$"),
        re.compile(r'^require\("github\.com/hopmesh/monorepo" not in text, "archived canonical repository remains"\)$'),
    ],
    "tools/workflow-secrets-guard.test.sh": [
        re.compile(r"^guard\.subprocess\.run = lambda \*a, \*\*k: FakeResult\(0, '\{\"full_name\": \"hopmesh/monorepo\", \"id\": 100, \"archived\": true\}'\)$"),
        re.compile(r'^guard\.verify_repo_identity\("hopmesh/monorepo"\)$'),
    ],
    "tools/native-attestation/create.test.mjs": [
        re.compile(r'^\["GITHUB_REPOSITORY", "hopmesh/monorepo"\],$'),
    ],
    "tools/pages-path-guard.test.sh": [
        re.compile(r"^'test \"\$REPOSITORY\" = hopmesh/hop', 'test \"\$REPOSITORY\" = hopmesh/monorepo'$"),
    ],
    "tools/release/release.test.sh": [
        re.compile(r'^assert not path\.startswith\("/repos/hopmesh/monorepo/"\), f"queried archived repo: \{path\}"$'),
    ],
    "tools/crates-publish.test.sh": [
        re.compile(r'^"repository": "https://github\.com/hopmesh/monorepo",$'),
    ],
    "tools/doc-path-guard.sh": [
        re.compile(r'^if re\.search\(r"\(hopmesh/monorepo\|hopmesh/internal\|hopmesh/platform\|\[a-zA-Z0-9_.-]\+/\[a-zA-Z0-9_.-]\+#\[0-9]\+\|historical\|monorepo\)", line\):$'),
        re.compile(r'^print\(f"\{target\}:\{lno\} cites unqualified pull request #\{num\} above highest known PR \{max_pr\} \(qualify with repository, e.g\. hopmesh/monorepo#\{num\}\)"\)$'),
    ],
    "tools/doc-path-guard.test.sh": [
        re.compile(r'^# Test 10: Qualified PR citation \(hopmesh/monorepo#138\) above the ceiling -> PASS \(PROC-015\)$'),
        re.compile(r'^lay_down "\$TMP/pr_qualified" "16" "16" "bundle-v16\.json" "- Fixes issue in hopmesh/monorepo#138 with qualification"$'),
    ],
    "tools/copybara/auto-export-plan.test.sh": [
        re.compile(r"^# that could not fail: when the canonical repository moved from hopmesh/monorepo to hopmesh/hop, `base`$"),
    ],
    "tools/copybara/bootstrap-packages.sh": [
        re.compile(r"^# hopmesh/monorepo in their repository field\. Nothing of ours is on PyPI, RubyGems, Hex, pub\.dev, or$"),
    ],
    "tools/copybara/copy.bara.sky": [
        re.compile(r"^# standing syncs, and they replayed the OLD private monorepo \(hopmesh/monorepo, since archived\) out$"),
    ],
}

# Documentation files allowed to reference hopmesh/monorepo within bounded historical sections.
DOCUMENTATION_ALLOWLIST = {
    "docs/runbooks/incident-response.md": "runbook_blocked_or_historical",
    "docs/runbooks/relay-enable-disable.md": "runbook_blocked_or_historical",
    "docs/repo-catalog.md": "catalog_doc",
    "docs/release-engineering.md": "release_doc",
    "docs/audit-history.md": "audit_record",
    ".agents/skills/hop-adversarial-audit/SKILL.md": "audit_record",
    ".agents/skills/hop-adversarial-audit/evals/trigger-evals.json": "audit_record",
    ".agents/skills/hop-adversarial-audit/fixtures/sample-ledger.json": "audit_record",
    ".agents/skills/hop-adversarial-audit/references/finding-schema.md": "audit_record",
    "tools/CLAUDE.md": "doc_prose",
    "tools/copybara/README.md": "doc_prose",
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
    # Subprocess list/array forms: ["git", "clone", ... "hopmesh/monorepo"]
    (
        re.compile(
            r"""(?i)(?:\[|\(|\b)(?:["\']?git["\']?|["\']?gh["\']?(?:\s*,?\s*["\']?repo["\']?)?)\s*,?\s*["\']?clone["\']?\s*,?.*hopmesh/monorepo"""
        ),
        "rejected executable clone of archived hopmesh/monorepo",
    ),
    # General clone + hopmesh/monorepo in same command/line
    (
        re.compile(r"""(?i)\bclone\b.*hopmesh/monorepo"""),
        "rejected executable clone of archived hopmesh/monorepo",
    ),
    (
        re.compile(r"""(?i)hopmesh/monorepo.*\bclone\b"""),
        "rejected executable clone of archived hopmesh/monorepo",
    ),
    # Quoted or array git operations
    (
        re.compile(
            r"""(?i)\bgit\s*["\']?(?:checkout|fetch|pull|push)["\']?\s*.*hopmesh/monorepo"""
        ),
        "rejected executable git operation on archived hopmesh/monorepo",
    ),
    # Workflow checkouts (case-insensitive, e.g. HopMesh/Monorepo)
    (
        re.compile(r"""(?i)repository:\s*["\']?hopmesh/monorepo["\']?"""),
        "rejected workflow source checkout of archived hopmesh/monorepo",
    ),
    (
        re.compile(r"""(?i)\buses:\s*actions/checkout@.*hopmesh/monorepo"""),
        "rejected workflow source checkout of archived hopmesh/monorepo",
    ),
    # Active GitHub CLI API, variable, secret, or workflow operations
    (
        re.compile(r"""(?i)\bgh\s+api\s+/repos/hopmesh/monorepo"""),
        "rejected active api call targeting archived hopmesh/monorepo",
    ),
    (
        re.compile(r"""(?i)\bgh\s+(?:variable|secret|workflow)\s+.*hopmesh/monorepo"""),
        "rejected active gh cli command targeting archived hopmesh/monorepo",
    ),
    # Active operational instructions targeting monorepo
    (
        re.compile(r"""(?i)\bIn\s+`?hopmesh/monorepo`?,\s*(?:verify|set|check|add)"""),
        "rejected active operational instruction targeting archived hopmesh/monorepo",
    ),
    (
        re.compile(r"""(?i)\bIn\s+`?hopmesh/monorepo`?\s+Settings"""),
        "rejected active operational instruction targeting archived hopmesh/monorepo",
    ),
    (
        re.compile(r"""(?i)\bto\s+`?main`?\s+in\s+`?hopmesh/monorepo`?"""),
        "rejected active operational instruction targeting archived hopmesh/monorepo",
    ),
    (
        re.compile(r"""(?i)\b(?:push|re-run|trigger|revert)\s+.*in\s+`?hopmesh/monorepo`?"""),
        "rejected active operational instruction targeting archived hopmesh/monorepo",
    ),
    (
        re.compile(r"""(?i)hopmesh/monorepo/\.github/workflows/"""),
        "rejected workflow reference in archived hopmesh/monorepo",
    ),
    (
        re.compile(r"""(?i)hopmesh/monorepo/infra/"""),
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


def check_doc_predicate(rel_path, pattern_class, line_str):
    """Validate allowed line predicates in documentation files."""
    if pattern_class == "runbook_blocked_or_historical":
        return any(p.search(line_str) for p in RUNBOOK_PERMITTED_PATTERNS)
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

    if pattern_class in ("catalog_doc", "release_doc", "doc_prose"):
        return True

    return False


def scan_file_for_violations(rel_path, text):
    errors = []
    lines = text.splitlines()

    # The guard and its self-test contain regex definitions and deliberate test fixtures
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

    # Priority 2: Exact occurrence allowlist for active tool, code, and test files
    if rel_path in ACTIVE_FILE_EXACT_ALLOWLIST:
        expected_patterns = ACTIVE_FILE_EXACT_ALLOWLIST[rel_path]
        matching_lines = [
            (lno, line.strip())
            for lno, line in enumerate(lines, 1)
            if re.search(r"(?i)hopmesh/monorepo", line)
        ]
        if len(matching_lines) > len(expected_patterns):
            errors.append(
                f"{rel_path}: occurrence count exceeded: expected at most {len(expected_patterns)}, found {len(matching_lines)}"
            )
        for lno, line_str in matching_lines:
            if any(e.startswith(f"{rel_path}:{lno}:") for e in errors):
                continue
            matched = any(p.search(line_str) for p in expected_patterns)
            if not matched:
                errors.append(
                    f"{rel_path}:{lno}: unallowlisted reference occurrence in active file: {line_str}"
                )
        return errors

    # Priority 3: Bounded allowlist for documentation files
    if rel_path in DOCUMENTATION_ALLOWLIST:
        pattern_class = DOCUMENTATION_ALLOWLIST[rel_path]
        for lno, line in enumerate(lines, 1):
            if not re.search(r"(?i)hopmesh/monorepo", line):
                continue
            if any(e.startswith(f"{rel_path}:{lno}:") for e in errors):
                continue
            if not check_doc_predicate(rel_path, pattern_class, line.strip()):
                errors.append(
                    f"{rel_path}:{lno}: line failed pattern class predicate '{pattern_class}': {line.strip()}"
                )
        return errors

    # Priority 4: Reject any other unallowlisted file containing hopmesh/monorepo
    if re.search(r"(?i)hopmesh/monorepo", text):
        for lno, line in enumerate(lines, 1):
            if re.search(r"(?i)hopmesh/monorepo", line) and not any(
                e.startswith(f"{rel_path}:{lno}:") for e in errors
            ):
                errors.append(
                    f"{rel_path}:{lno}: unallowlisted reference to archived repository hopmesh/monorepo"
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
