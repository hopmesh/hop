#!/usr/bin/env bash
# Keep the deploy gate's required-check allowlist honest (infra-r2-02).
#
# Three lists must agree, or the gate silently protects the wrong thing:
#   1. the job `name:` fields in .github/workflows/ci.yml (the checks that actually run),
#   2. _REQUIRED_CHECKS in infra/cloudbuild.trigger.yaml (what the runtime deploy gate requires),
#   3. the "CI / ..." names documented in infra/README.md ("Deploy gate + branch protection").
#
# This asserts (1) == (2) exactly (the authoritative pair). It also warns if any (1) name is not
# mentioned in the README so the human-facing branch-protection list doesn't drift. Run in CI so a
# renamed/added/dropped CI job forces a matching allowlist edit in the same PR.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CI="$ROOT/.github/workflows/ci.yml"
TRIGGER="$ROOT/infra/cloudbuild.trigger.yaml"
README="$ROOT/infra/README.md"

# (1) Every `    name: <...>` under jobs: in ci.yml. Job name lines are indented exactly 4 spaces and
# are the FIRST key of a job block. Step names are indented deeper (>= 8) so this doesn't catch them.
ci_names="$(python3 - "$CI" <<'PY'
import sys, re
names = []
in_jobs = False
job_indent = None
for line in open(sys.argv[1]):
    if re.match(r'^jobs:\s*$', line):
        in_jobs = True
        continue
    if not in_jobs:
        continue
    # A job key: exactly two-space indent, "<id>:" with nothing after.
    m = re.match(r'^  (\S[^:]*):\s*$', line)
    if m:
        job_indent = True
        continue
    # The job's name: is the first 4-space "name:" after a job key.
    m = re.match(r'^    name:\s*(.+?)\s*$', line)
    if m and job_indent:
        names.append(m.group(1))
        job_indent = False
for n in names:
    print(n)
PY
)"

# (2) The _REQUIRED_CHECKS block-scalar lines in the trigger.
req_names="$(python3 - "$TRIGGER" <<'PY'
import sys, re
lines = open(sys.argv[1]).read().splitlines()
out = []
i = 0
while i < len(lines):
    if re.match(r'^\s*_REQUIRED_CHECKS:\s*\|\s*$', lines[i]):
        i += 1
        # block scalar: indented more than the key (which is 2 spaces -> lines are 4 spaces).
        while i < len(lines) and (lines[i].strip() == "" or lines[i].startswith("    ")):
            if lines[i].strip():
                out.append(lines[i].strip())
            else:
                break
            i += 1
        break
    i += 1
for n in out:
    print(n)
PY
)"

if [ -z "$ci_names" ]; then
  echo "::error:: could not parse any job names from $CI"; exit 1
fi
if [ -z "$req_names" ]; then
  echo "::error:: could not parse _REQUIRED_CHECKS from $TRIGGER"; exit 1
fi

# Compare as sorted sets.
ci_sorted="$(printf '%s\n' "$ci_names" | sort)"
req_sorted="$(printf '%s\n' "$req_names" | sort)"

if [ "$ci_sorted" != "$req_sorted" ]; then
  echo "::error:: ci.yml job names and infra/cloudbuild.trigger.yaml _REQUIRED_CHECKS disagree."
  echo "--- only in ci.yml (add to _REQUIRED_CHECKS) ---"
  comm -23 <(printf '%s\n' "$ci_sorted") <(printf '%s\n' "$req_sorted") || true
  echo "--- only in _REQUIRED_CHECKS (stale; remove or rename) ---"
  comm -13 <(printf '%s\n' "$ci_sorted") <(printf '%s\n' "$req_sorted") || true
  exit 1
fi

# README warning-only cross-check: each CI job name should be reflected in the README deploy-gate list.
missing_readme=0
while IFS= read -r n; do
  [ -z "$n" ] && continue
  # The README lists short forms (e.g. "Rust"); match on the first word of the job name.
  first="${n%% *}"
  if ! grep -qF "$first" "$README"; then
    echo "::warning:: CI job '$n' not obviously reflected in infra/README.md deploy-gate list"
    missing_readme=1
  fi
done <<EOF
$ci_names
EOF

echo "required-check allowlist is in sync ($(printf '%s\n' "$ci_names" | grep -c . ) jobs): ci.yml == cloudbuild.trigger.yaml _REQUIRED_CHECKS"
[ "$missing_readme" -eq 0 ] || echo "(README cross-check emitted warnings; not fatal)"
