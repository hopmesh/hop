#!/usr/bin/env python3
"""workflow-if-guard: fail if a workflow `if:` expression carries an embedded newline.

Why this exists. pr-automerge.yml's author gate shipped as a `>-` folded scalar whose continuation
lines were each indented FURTHER than the first:

    if: >-
      ${{ !github.event.pull_request.draft
        && (contains(...)
          || ...) }}

In a YAML folded scalar, more-indented lines are preserved LITERALLY rather than folded to spaces, so
the value reached GitHub as one string with real newlines inside the `${{ }}`. The job then skipped on
every pull request, which meant auto-merge was never armed and PRs sat green and unmerged.

The failure shape is what makes this worth a guard: a job whose `if` does not match is SKIPPED, not
failed, so CI stays entirely green while a merge gate quietly does nothing. Nothing else in this repo
would have caught it.

The rule: any `if:` value containing `${{` must be a single line. Folding across lines is still fine
when done with equal indentation (that folds to spaces); this only rejects a value that actually
retained a newline inside an expression.

Usage:  tools/workflow-if-guard.py [--workflows DIR]
"""

import argparse
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover - CI always has pyyaml
    print("workflow-if-guard: FAIL (pyyaml unavailable)", file=sys.stderr)
    sys.exit(1)


def walk_ifs(node, trail):
    """Yield (dotted_path, value) for every `if:` mapping key, at any depth."""
    if isinstance(node, dict):
        for key, value in node.items():
            here = trail + [str(key)]
            if key == "if" and isinstance(value, str):
                yield ".".join(trail) or "<root>", value
            else:
                yield from walk_ifs(value, here)
    elif isinstance(node, list):
        for index, item in enumerate(node):
            yield from walk_ifs(item, trail + [f"[{index}]"])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--workflows", default=".github/workflows")
    args = parser.parse_args()

    root = Path(args.workflows)
    if not root.is_dir():
        print(f"workflow-if-guard: MISSING workflows dir {root}", file=sys.stderr)
        return 1

    files = sorted(p for p in root.iterdir() if p.suffix in (".yml", ".yaml"))
    if not files:
        print(f"workflow-if-guard: MISSING no workflow files under {root}", file=sys.stderr)
        return 1

    failures = 0
    checked = 0
    for path in files:
        try:
            doc = yaml.safe_load(path.read_text(encoding="utf-8"))
        except yaml.YAMLError as exc:
            print(f"workflow-if-guard: UNPARSEABLE {path}: {exc}", file=sys.stderr)
            failures += 1
            continue
        for where, value in walk_ifs(doc, []):
            checked += 1
            if "${{" in value and "\n" in value:
                # Show the value with newlines made visible, so the diagnosis is obvious.
                shown = value.replace("\n", "\\n")
                print(
                    f"workflow-if-guard: NEWLINE-IN-EXPRESSION {path} at {where}\n"
                    f"    an `if:` expression retained a literal newline, so GitHub will not\n"
                    f"    evaluate it as intended and the job will SKIP silently (green CI, dead gate).\n"
                    f"    Put it on one line, or fold with EQUAL indentation on every line.\n"
                    f"    got: {shown[:200]}",
                    file=sys.stderr,
                )
                failures += 1

    if failures:
        print(f"workflow-if-guard: FAIL ({failures} bad `if:` expression(s))", file=sys.stderr)
        return 1
    print(f"workflow-if-guard: OK ({checked} `if:` expressions across {len(files)} workflows)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
