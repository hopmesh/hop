#!/usr/bin/env python3
"""ci-path-ownership-guard: ensure every tracked top-level tree and hostile path
has declared CI job ownership (INFRA-012).

Validates that:
1. Every tracked top-level tree (file or directory) in the repository is matched
   by at least one path filter in the `changes` job of .github/workflows/ci.yml.
2. apps/react-native/HopDemo/** is owned by sdk_react_native (react-native-sdk job).
3. apps/ble-lab/** routes to android as well as apple.
4. fuzz/Cargo.toml and fuzz/** route to rust.
5. Root markdown files (DESIGN.md, SECURITY.md, MECHANISMS.md, README.md,
   CLAUDE.md, CONTRIBUTING.md) route to docs (docs-tokens job).

Usage:
    python3 tools/ci-path-ownership-guard.py [--ci CI_YML] [--repo-root DIR] [--files-list FILE]
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("ci-path-ownership-guard: FAIL (pyyaml unavailable)", file=sys.stderr)
    sys.exit(1)


def glob_to_regex(pat: str) -> re.Pattern:
    """Convert a dorny/paths-filter glob pattern to a compiled regex."""
    res = []
    i = 0
    n = len(pat)
    while i < n:
        c = pat[i]
        if c == "*":
            if i + 1 < n and pat[i + 1] == "*":
                if i + 2 < n and pat[i + 2] == "/":
                    res.append("(?:.*/)?")
                    i += 3
                    continue
                else:
                    res.append(".*")
                    i += 2
                    continue
            else:
                res.append("[^/]*")
                i += 1
                continue
        elif c == "?":
            res.append("[^/]")
            i += 1
            continue
        elif c in r"\.[]{}()+^$|":
            res.append("\\" + c)
            i += 1
            continue
        else:
            res.append(c)
            i += 1
            continue
    return re.compile("^" + "".join(res) + "$")


def parse_filters(ci_path: Path) -> dict[str, list[re.Pattern]]:
    """Parse the `changes` job filter map from ci.yml."""
    raw = yaml.safe_load(ci_path.read_text(encoding="utf-8"))
    jobs = raw.get("jobs", {})
    changes_job = jobs.get("changes", {})
    steps = changes_job.get("steps", [])

    filters_str = None
    for step in steps:
        uses = step.get("uses", "")
        if "paths-filter" in uses:
            filters_str = step.get("with", {}).get("filters")
            break

    if not filters_str:
        raise ValueError(f"Could not find dorny/paths-filter step in {ci_path}")

    parsed = yaml.safe_load(filters_str)
    if not isinstance(parsed, dict):
        raise ValueError(f"Malformed filters block in {ci_path}")

    compiled = {}
    for filter_name, patterns in parsed.items():
        if isinstance(patterns, list):
            compiled[filter_name] = [glob_to_regex(p) for p in patterns if isinstance(p, str)]
        else:
            compiled[filter_name] = []
    return compiled


def match_path(path_str: str, compiled_filters: dict[str, list[re.Pattern]]) -> set[str]:
    """Return the set of filter names that match path_str."""
    matching = set()
    for name, regexes in compiled_filters.items():
        if any(r.match(path_str) for r in regexes):
            matching.add(name)
    return matching


def check_ownership(
    ci_path: Path,
    repo_root: Path,
    files_list_path: Path | None = None,
) -> list[str]:
    errors = []

    try:
        filters = parse_filters(ci_path)
    except Exception as exc:
        return [f"Failed to parse {ci_path}: {exc}"]

    # 1. Collect tracked files
    if files_list_path:
        files = [
            line.strip()
            for line in files_list_path.read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]
    else:
        try:
            out = subprocess.check_output(
                ["git", "-C", str(repo_root), "ls-files"], text=True
            )
            files = [line.strip() for line in out.splitlines() if line.strip()]
        except Exception as exc:
            return [f"Failed to run git ls-files in {repo_root}: {exc}"]

    if not files:
        return [f"No tracked files found in {repo_root}"]

    # 2. Check that every tracked file matches at least one filter
    unmatched_files = []
    unmatched_top_trees = set()
    for f in files:
        matches = match_path(f, filters)
        if not matches:
            unmatched_files.append(f)
            top_tree = f.split("/", 1)[0]
            unmatched_top_trees.add(top_tree)

    if unmatched_files:
        errors.append(
            f"{len(unmatched_files)} tracked file(s) across {len(unmatched_top_trees)} top-level tree(s) "
            f"not matched by any job filter: {', '.join(sorted(unmatched_top_trees))}"
        )

    # 3. Invariant checks for named hostile paths (INFRA-012)
    invariants = [
        ("apps/react-native/HopDemo/package.json", "sdk_react_native"),
        ("apps/react-native/HopDemo/App.tsx", "sdk_react_native"),
        ("apps/ble-lab/android/app/src/main/java/sh/hopme/blelab/MainActivity.kt", "android"),
        ("apps/ble-lab/android/app/src/main/java/sh/hopme/blelab/MainActivity.kt", "apple"),
        ("testkit/tk", "automation"),
        ("testkit/soak.workflow.js", "automation"),
        ("fuzz/Cargo.toml", "rust"),
        ("fuzz/Cargo.lock", "rust"),
        ("DESIGN.md", "docs"),
        ("SECURITY.md", "docs"),
        ("MECHANISMS.md", "docs"),
        ("README.md", "docs"),
        ("CLAUDE.md", "docs"),
        ("CONTRIBUTING.md", "docs"),
    ]

    for path_str, required_filter in invariants:
        matches = match_path(path_str, filters)
        if required_filter not in matches and "full" not in matches:
            errors.append(
                f"Hostile path '{path_str}' must match filter '{required_filter}' (got: {sorted(matches)})"
            )

    # testkit must NOT be matched under docs filter (INFRA-012)
    testkit_docs_matches = [
        f for f in files if f.startswith("testkit/") and "docs" in match_path(f, filters)
    ]
    if testkit_docs_matches:
        errors.append(
            f"testkit files must not be routed to 'docs' filter (INFRA-012): {sorted(testkit_docs_matches)[:3]}"
        )

    # 4. Job step consumption contracts (INFRA-012):
    # Routing a path to a filter is necessary but not sufficient: the target job must
    # contain an observable step that builds or tests the component.
    raw = yaml.safe_load(ci_path.read_text(encoding="utf-8"))
    jobs = raw.get("jobs", {}) if isinstance(raw, dict) else {}

    step_contracts = [
        {
            "path": "apps/react-native/HopDemo/package.json",
            "filter": "sdk_react_native",
            "job": "react-native-sdk",
            "step_marker": "apps/react-native/HopDemo",
        },
        {
            "path": "apps/ble-lab/android/app/src/main/java/sh/hopme/blelab/MainActivity.kt",
            "filter": "android",
            "job": "android",
            "step_marker": "apps/ble-lab/android",
        },
        {
            "path": "testkit/tk",
            "filter": "automation",
            "job": "automation",
            "step_marker": "testkit",
        },
    ]

    for contract in step_contracts:
        path_str = contract["path"]
        req_filter = contract["filter"]
        target_job = contract["job"]
        marker = contract["step_marker"]

        if target_job not in jobs:
            errors.append(
                f"Required job '{target_job}' for path '{path_str}' not found in {ci_path}"
            )
            continue

        job_steps = jobs[target_job].get("steps", []) if isinstance(jobs[target_job], dict) else []
        step_matched = False
        for step in job_steps:
            if not isinstance(step, dict):
                continue
            step_name = str(step.get("name", ""))
            step_run = str(step.get("run", ""))
            step_uses = str(step.get("uses", ""))
            step_text = f"{step_name} {step_run} {step_uses}"
            if marker in step_text:
                step_matched = True
                break

        if not step_matched:
            errors.append(
                f"Job '{target_job}' routed from '{req_filter}' has no step building or testing '{path_str}' "
                f"(expected step marker '{marker}') (INFRA-012)"
            )

    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--ci",
        type=Path,
        default=Path(".github/workflows/ci.yml"),
        help="Path to ci.yml workflow file",
    )
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path("."),
        help="Path to repository root",
    )
    parser.add_argument(
        "--files-list",
        type=Path,
        default=None,
        help="Optional file containing newline-delimited list of repo-relative paths",
    )

    args = parser.parse_args()
    errors = check_ownership(args.ci, args.repo_root, args.files_list)

    if errors:
        for err in errors:
            print(f"::error::{err}", file=sys.stderr)
        return 1

    print("ci-path-ownership-guard: OK (all tracked paths and hostile fixtures owned)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
