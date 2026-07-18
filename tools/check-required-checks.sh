#!/usr/bin/env bash
# Validate the two independent required-check contracts.
#
# Branch protection requires the single aggregate `CI gate`. That gate must run
# after every other CI job, even after failures, and reject failed or cancelled
# dependencies while allowing path-filtered skips.
#
# Trusted deployment separately authenticates the complete CI job set listed in
# infra/bootstrap/variables.tf: path detector, every product job, and aggregate gate.
# The README list is kept exact too.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CI="${CI_FILE:-$ROOT/.github/workflows/ci.yml}"
BOOTSTRAP="${BOOTSTRAP_FILE:-$ROOT/infra/bootstrap/variables.tf}"
README="${README_FILE:-$ROOT/infra/README.md}"

python3 - "$CI" "$BOOTSTRAP" "$README" <<'PY'
import re
import sys


ci_path, bootstrap_path, readme_path = sys.argv[1:]
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

bootstrap_lines = open(bootstrap_path, encoding="utf-8").read().splitlines()
allowlist = []
in_variable = False
in_default = False
for line in bootstrap_lines:
    if re.fullmatch(r'variable\s+"github_required_checks"\s*\{\s*', line):
        in_variable = True
        continue
    if in_variable and re.match(r"^\s*default\s*=\s*\[\s*$", line):
        in_default = True
        continue
    if in_default and re.match(r"^\s*\]\s*$", line):
        break
    if in_default:
        match = re.match(r'^\s*"(.*)",\s*$', line)
        if match:
            allowlist.append(match.group(1))

trusted_names = [names[job_id] for job_id in job_ids if job_id in names]
if not allowlist:
    errors.append(f"could not parse github_required_checks from {bootstrap_path}")
elif allowlist != trusted_names:
    missing = [name for name in trusted_names if name not in allowlist]
    extra = [name for name in allowlist if name not in trusted_names]
    if missing:
        errors.append("deploy-provenance allowlist is missing: " + ", ".join(missing))
    if extra:
        errors.append("deploy-provenance allowlist has stale names: " + ", ".join(extra))
    if not missing and not extra:
        errors.append("deploy-provenance allowlist order differs from ci.yml")

readme_lines = open(readme_path, encoding="utf-8").read().splitlines()
documented = []
in_documented_list = False
for line in readme_lines:
    if "authenticated deploy-provenance job set currently requires" in line:
        in_documented_list = True
        continue
    if in_documented_list and line.startswith("## "):
        break
    if in_documented_list:
        match = re.fullmatch(r"- `(.+)`", line)
        if match:
            documented.append(match.group(1))
if documented != trusted_names:
    errors.append("infra/README.md trusted-job list differs from ci.yml")

if errors:
    for error in errors:
        print(f"::error:: {error}", file=sys.stderr)
    raise SystemExit(1)

print(
    "required-check contracts OK: branch protection uses CI gate over "
    f"{len(job_ids) - 1} dependencies; deploy provenance authenticates "
    f"all {len(trusted_names)} workflow jobs"
)
PY
