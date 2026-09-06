#!/usr/bin/env python3
"""workflow-run-syntax-guard: fail if any workflow `run:` script fails bash -n syntax validation.

Why this exists (REL-006). A workflow run script lost its closing `done` for a `for` loop:

    for target in ...; do
      cargo +esp build ...
      cp ...
    # missing `done`

The error surfaced only when the job was finally scheduled:
    syntax error: unexpected end of file from `for' command on line 4

Because GitHub Actions workflow runs can be gated off by environment credentials or path filters,
shell syntax errors inside `run:` blocks can sit undetected for long periods.

This guard extracts every `run:` script block from all workflow files and validates its syntax
with `bash -n`. In addition, if `actionlint` is available on the path, it runs static workflow linting
across each workflow file.

Usage:  tools/workflow-run-syntax-guard.py [--workflows DIR]
"""

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover - CI always has pyyaml
    print("workflow-run-syntax-guard: FAIL (pyyaml unavailable)", file=sys.stderr)
    sys.exit(1)


def walk_runs(node, trail):
    """Yield (dotted_path, value) for every `run:` mapping key with a string value."""
    if isinstance(node, dict):
        if "run" in node and isinstance(node["run"], str):
            label = ".".join(trail) or "<root>"
            name = node.get("name")
            if name:
                label += f" ({name!r})"
            yield label, node["run"]
        for key, value in node.items():
            if key != "run":
                yield from walk_runs(value, trail + [str(key)])
    elif isinstance(node, list):
        for index, item in enumerate(node):
            yield from walk_runs(item, trail + [f"[{index}]"])


def main():
    parser = argparse.ArgumentParser(description="Validate syntax of workflow run scripts.")
    parser.add_argument("--workflows", default=".github/workflows")
    args = parser.parse_args()

    root = Path(args.workflows)
    if not root.is_dir():
        print(f"workflow-run-syntax-guard: MISSING workflows dir {root}", file=sys.stderr)
        return 1

    files = sorted(p for p in root.iterdir() if p.suffix in (".yml", ".yaml"))
    if not files:
        print(f"workflow-run-syntax-guard: MISSING no workflow files under {root}", file=sys.stderr)
        return 1

    failures = 0
    checked = 0

    for path in files:
        try:
            doc = yaml.safe_load(path.read_text(encoding="utf-8"))
        except yaml.YAMLError as exc:
            print(f"workflow-run-syntax-guard: UNPARSEABLE {path}: {exc}", file=sys.stderr)
            failures += 1
            continue

        for where, script in walk_runs(doc, []):
            checked += 1
            proc = subprocess.run(
                ["bash", "-n"],
                input=script,
                text=True,
                capture_output=True,
            )
            if proc.returncode != 0:
                err = proc.stderr.strip() or f"bash -n exited with code {proc.returncode}"
                print(
                    f"workflow-run-syntax-guard: SYNTAX-ERROR in {path} at {where}:\n"
                    f"    {err}",
                    file=sys.stderr,
                )
                failures += 1

    actionlint_bin = shutil.which("actionlint")
    if actionlint_bin:
        for path in files:
            res = subprocess.run(
                [actionlint_bin, str(path)],
                capture_output=True,
                text=True,
            )
            if res.returncode != 0:
                msg = res.stdout.strip() or res.stderr.strip()
                print(
                    f"workflow-run-syntax-guard: ACTIONLINT-ERROR in {path}:\n"
                    f"    {msg}",
                    file=sys.stderr,
                )
                failures += 1

    if failures:
        print(
            f"workflow-run-syntax-guard: FAIL ({failures} error(s) across {len(files)} workflow(s))",
            file=sys.stderr,
        )
        return 1

    lint_note = " (including actionlint)" if actionlint_bin else ""
    print(
        f"workflow-run-syntax-guard: OK ({checked} `run:` block(s) validated{lint_note} across {len(files)} workflow(s))"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
