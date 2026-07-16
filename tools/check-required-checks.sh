#!/usr/bin/env bash
# Keep the deploy gate honest in the aggregate-gate model (infra-r2-02).
#
# The single required check is `CI gate`: branch protection on `main` and the Cloud Build deploy gate
# (infra/cloudbuild.trigger.yaml _REQUIRED_CHECKS) both require only it, and the gate passes iff every
# CI job that needed to run passed (a path-filtered skip is fine). This guard asserts the invariants
# that keep that single gate trustworthy, so a drift fails the same PR:
#
#   1. _REQUIRED_CHECKS in cloudbuild.trigger.yaml is EXACTLY [CI gate].
#   2. ci.yml has a job whose name is "CI gate".
#   3. that gate job `needs:` EVERY other ci.yml job except `changes` (the path-filter job). Otherwise a
#      newly added job could fail-open: it runs and fails, but the gate never waited for it, so the gate
#      stays green and the failure reaches main / a deploy.
#   4. every job sets an explicit, literal (non-templated) `name:` (so it is visible to humans + the
#      branch-protection audit; a ${{ }} name never matches a real check-run).
#
# self-tested by tools/check-required-checks.test.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CI="${CI_FILE:-$ROOT/.github/workflows/ci.yml}"
TRIGGER="${TRIGGER_FILE:-$ROOT/infra/cloudbuild.trigger.yaml}"

python3 - "$CI" "$TRIGGER" <<'PY'
import sys, re

ci_path, trigger_path = sys.argv[1], sys.argv[2]

# ---- parse ci.yml: ordered job ids, id->name, and the gate job's `needs:` ids -----------------------
lines = open(ci_path).read().splitlines()
in_jobs = False
job_ids = []
names = {}
templated = []
gate_needs = set()
cur = None
i, n = 0, len(lines)
while i < n:
    line = lines[i]
    if re.match(r'^jobs:\s*$', line):
        in_jobs = True; i += 1; continue
    if not in_jobs:
        i += 1; continue
    # Skip YAML comments so a two-space job-level comment ("  # CI gate: ...") is not read as a job id.
    if line.lstrip().startswith('#'):
        i += 1; continue
    # A job key: two-space indent then "<id>:" plus whitespace/anchor/inline-map/EOL. Matching ":(\s|$)"
    # (not ":\s*$") so an anchor/inline-defined job is still seen as a job boundary (pass-18 F-CI-2).
    m = re.match(r'^  (\S[^:]*):(\s|$)', line)
    if m:
        cur = m.group(1)
        job_ids.append(cur)
        i += 1; continue
    m = re.match(r'^    name:\s*(.+?)\s*$', line)
    if m and cur is not None:
        nm = m.group(1)
        if '${{' in nm:               # F-CI-6: a templated name never equals a real check-run name.
            templated.append(cur)
        names[cur] = nm
        i += 1; continue
    # Capture the gate job's needs list (only the job literally named "CI gate").
    m = re.match(r'^    needs:\s*(.*)$', line)
    if m and cur is not None and names.get(cur) == "CI gate":
        inline = m.group(1).strip()
        if inline.startswith('['):    # inline form: needs: [a, b]
            gate_needs.update(re.findall(r'[A-Za-z0-9_-]+', inline))
            i += 1; continue
        i += 1                        # block form: following "      - <id>" lines
        while i < n and re.match(r'^      - \S', lines[i]):
            gate_needs.add(lines[i].split('- ', 1)[1].strip())
            i += 1
        continue
    i += 1

nameless = [j for j in job_ids if j not in names]

# ---- parse _REQUIRED_CHECKS block scalar from the trigger --------------------------------------------
req = []
tl = open(trigger_path).read().splitlines()
j = 0
while j < len(tl):
    if re.match(r'^\s*_REQUIRED_CHECKS:\s*\|\s*$', tl[j]):
        j += 1
        while j < len(tl) and (tl[j].strip() == "" or tl[j].startswith("    ")):
            if tl[j].strip():
                req.append(tl[j].strip())
            else:
                break
            j += 1
        break
    j += 1

# ---- assert the invariants --------------------------------------------------------------------------
errs = []
if nameless:
    errs.append("every job must set an explicit literal name:; nameless: " + ", ".join(nameless))
if templated:
    errs.append("job names must be literal (a ${{ }} template never matches a check-run): " + ", ".join(templated))

gate_id = next((jid for jid, nm in names.items() if nm == "CI gate"), None)
if gate_id is None:
    errs.append("ci.yml has no job named 'CI gate' (the single required check)")

if req != ["CI gate"]:
    errs.append("_REQUIRED_CHECKS must be exactly [CI gate], got: %r" % (req,))

if gate_id is not None:
    should = set(job_ids) - {gate_id, "changes"}
    missing = sorted(should - gate_needs)
    if missing:
        errs.append("the 'CI gate' job must `needs:` every other job so it waits for them (else a "
                    "failing new job fails open); missing from its needs: " + ", ".join(missing))

if errs:
    for e in errs:
        sys.stderr.write("::error:: " + e + "\n")
    sys.exit(1)

other = len(set(job_ids) - {gate_id, "changes"})
print("required-check model OK: deploy gate requires exactly [CI gate]; the gate needs all %d other "
      "jobs; every job literally named" % other)
PY
