#!/usr/bin/env bash
# Validate the branch-protection required-check contract.
#
# GitHub is the only change-management gate. Branch protection on `main` requires the single aggregate
# `CI gate` context (checked live by tools/check-branch-protection.sh). This guard keeps that aggregate
# HONEST at the source: `CI gate` must run after every other CI job, even after failures, and reject
# failed or cancelled dependencies while allowing path-filtered skips. It also refuses a CI job that a
# renamed/anchored/templated name could hide, so a job cannot gate merges while dodging the aggregate.
#
# There is no separate GCP deploy gate anymore: the runtime deploy workflows moved to
# hopmesh/platform, which fires on the CI workflow's own success conclusion. But the canonical CI job set still has one live
# consumer: tools/release-provenance.py verifies a mirror release tag's CI ran every one of these jobs,
# and it reads them from tools/required-checks.json. So this guard ALSO pins that config to ci.yml (in
# order), so a renamed/added/dropped job forces a matching config edit in the same PR.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CI="${CI_FILE:-$ROOT/.github/workflows/ci.yml}"
REQUIRED="${REQUIRED_CHECKS_FILE:-$ROOT/tools/required-checks.json}"

python3 - "$CI" "$REQUIRED" <<'PY'
import json
import re
import sys


ci_path, required_path = sys.argv[1:3]
ci_lines = open(ci_path, encoding="utf-8").read().splitlines()


def job_blocks(lines):
    in_jobs = False
    starts = []
    for index, line in enumerate(lines):
        if re.fullmatch(r"jobs:\s*", line):
            in_jobs = True
            continue
        if not in_jobs or line.lstrip().startswith("#"):
            continue
        match = re.match(r"^  (\S[^:]*):(\s|$)", line)
        if match:
            starts.append((match.group(1), index))
    blocks = []
    for offset, (job_id, start) in enumerate(starts):
        end = starts[offset + 1][1] if offset + 1 < len(starts) else len(lines)
        blocks.append((job_id, lines[start:end]))
    return blocks


def parse_needs(block):
    for index, line in enumerate(block):
        match = re.match(r"^    needs:\s*(.*)$", line)
        if not match:
            continue
        inline = match.group(1).split("#", 1)[0].strip()
        if inline.startswith("["):
            return set(re.findall(r"[A-Za-z0-9_-]+", inline))
        if inline:
            if re.fullmatch(r"[A-Za-z0-9_-]+", inline):
                return {inline}
            return {"<invalid-needs>"}
        needs = set()
        for nested in block[index + 1 :]:
            item = re.match(r"^      -\s+([A-Za-z0-9_-]+)\s*$", nested)
            if not item:
                break
            needs.add(item.group(1))
        return needs
    return set()


blocks = job_blocks(ci_lines)
errors = []
if not blocks:
    errors.append(f"could not parse any jobs from {ci_path}")

job_ids = []
names = {}
templated = []
duplicate_ids = []
for job_id, block in blocks:
    if job_id in job_ids:
        duplicate_ids.append(job_id)
    job_ids.append(job_id)
    matches = [
        match.group(1).strip()
        for line in block
        if (match := re.match(r"^    name:\s*(.+?)\s*$", line))
    ]
    if len(matches) != 1:
        errors.append(f"job {job_id!r} must set exactly one explicit literal name")
        continue
    name = matches[0]
    names[job_id] = name
    if "${{" in name:
        templated.append(job_id)

if duplicate_ids:
    errors.append("duplicate CI job ids: " + ", ".join(sorted(set(duplicate_ids))))
if templated:
    errors.append("templated CI job names cannot be authenticated: " + ", ".join(templated))

name_values = list(names.values())
duplicate_names = sorted({name for name in name_values if name_values.count(name) > 1})
if duplicate_names:
    errors.append("duplicate CI job names: " + ", ".join(duplicate_names))

gate_ids = [job_id for job_id, name in names.items() if name == "CI gate"]
gate_id = gate_ids[0] if len(gate_ids) == 1 else None
automation_ids = [job_id for job_id, name in names.items() if name == "Automation authority guards"]
if len(automation_ids) != 1:
    errors.append(
        "ci.yml must define exactly one job named 'Automation authority guards', "
        f"found {len(automation_ids)}"
    )
else:
    automation_block = next(block for job_id, block in blocks if job_id == automation_ids[0])
    if parse_needs(automation_block):
        errors.append("Automation authority guards must not depend on a path-filtered job")
    if any(re.match(r"^    if:\s*", line) for line in automation_block):
        errors.append("Automation authority guards must not have a job-level condition")
    automation_text = "\n".join(automation_block)
    if "tools/commit-message-guard.sh --github-event" not in automation_text:
        errors.append("Automation authority guards must run commit-message-guard unconditionally (PROC-016)")
    for other_id, other_block in blocks:
        if other_id != automation_ids[0] and "tools/commit-message-guard.sh" in "\n".join(other_block):
            errors.append(f"job {other_id} must not run commit-message-guard (PROC-016)")
if len(gate_ids) != 1:
    errors.append(f"ci.yml must define exactly one job named 'CI gate', found {len(gate_ids)}")
else:
    gate_block = next(block for job_id, block in blocks if job_id == gate_id)
    gate_needs = parse_needs(gate_block)
    expected_needs = set(job_ids) - {gate_id}
    missing = sorted(expected_needs - gate_needs)
    extra = sorted(gate_needs - expected_needs)
    if missing:
        errors.append("CI gate is missing needs: " + ", ".join(missing))
    if extra:
        errors.append("CI gate has unknown needs: " + ", ".join(extra))
    gate_text = "\n".join(gate_block)
    if not re.search(r"^    if:\s*always\(\)\s*$", gate_text, re.MULTILINE):
        errors.append("CI gate must use job-level `if: always()`")
    verdict_tokens = (
        "contains(needs.*.result, 'failure')",
        "contains(needs.*.result, 'cancelled')",
        "needs.changes.result != 'success'",
        "needs.automation.result != 'success'",
        "exit 1",
    )
    if any(token not in gate_text for token in verdict_tokens):
        errors.append("CI gate must fail on failed or cancelled dependencies")

# Keep tools/required-checks.json (release-provenance's canonical job set) locked to ci.yml, in order.
trusted_names = [names[job_id] for job_id in job_ids if job_id in names]
try:
    required_data = json.loads(open(required_path, encoding="utf-8").read())
    canonical = required_data.get("required_checks")
except (OSError, json.JSONDecodeError) as error:
    canonical = None
    errors.append(f"could not read required_checks from {required_path}: {error}")
if canonical is not None:
    if not isinstance(canonical, list):
        errors.append("required_checks must be a JSON list of job names")
    elif canonical != trusted_names:
        missing = [name for name in trusted_names if name not in canonical]
        extra = [name for name in canonical if name not in trusted_names]
        if missing:
            errors.append("required-checks config is missing: " + ", ".join(missing))
        if extra:
            errors.append("required-checks config has stale names: " + ", ".join(extra))
        if not missing and not extra:
            errors.append("required-checks config order differs from ci.yml")

if errors:
    for error in errors:
        print(f"::error:: {error}", file=sys.stderr)
    raise SystemExit(1)

print(
    "required-check contract OK: branch protection uses the aggregate CI gate over "
    f"{len(job_ids) - 1} dependencies; tools/required-checks.json pins all "
    f"{len(trusted_names)} job names for release-provenance"
)
PY
