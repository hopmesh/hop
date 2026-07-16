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
pending = None      # a job id whose `name:` we have not seen yet
nameless = []       # job ids that reached the next job (or EOF) with no name:
templated = []      # job names carrying a ${{ }} expression (a matrix/expr template)
for line in open(sys.argv[1]):
    if re.match(r'^jobs:\s*$', line):
        in_jobs = True
        continue
    if not in_jobs:
        continue
    # Skip YAML comments: a two-space-indented job-level comment like "  # Gate: ..." would otherwise
    # match the job-key regex below (captured as a job id "# Gate") and then be flagged nameless. A
    # comment never defines a job. (Step-level block content is indented deeper and is not scanned here.)
    if line.lstrip().startswith("#"):
        continue
    # A job key: two-space indent, "<id>:" then whitespace, an anchor, an inline map, or end of line.
    # Matching ":(\s|$)" rather than the old ":\s*$" is deliberate (pass-18 F-CI-2): a job defined with a
    # YAML anchor ("sneaky: &anchor") or inline map put ANYTHING after the colon, so the old anchored
    # regex never saw it as a job boundary at all, letting it hide from this allowlist sync entirely (it
    # ran in CI, produced a check-run, and was never required by the deploy gate). Now any such job is
    # seen; if it then has no `    name:` line it is flagged nameless below (fail-loud, not fail-open).
    m = re.match(r'^  (\S[^:]*):(\s|$)', line)
    if m:
        if pending is not None:
            nameless.append(pending)
        pending = m.group(1)
        continue
    # The job's name: is the first 4-space "name:" after a job key.
    m = re.match(r'^    name:\s*(.+?)\s*$', line)
    if m and pending is not None:
        nm = m.group(1)
        # F-CI-6: a matrix/expression-templated name (e.g. "Test (${{ matrix.os }})") is NEVER the
        # literal check-run name GitHub produces (it expands to "Test (ubuntu-latest)" etc.), so an
        # allowlist entry matching the template can never match a real check and the deploy gate would
        # poll forever. Refuse a templated job name outright.
        if '${{' in nm:
            templated.append(pending)
        names.append(nm)
        pending = None
if pending is not None:
    nameless.append(pending)
if nameless:
    sys.stderr.write("NAMELESS_JOBS " + ",".join(nameless) + "\n")
    sys.exit(7)
if templated:
    sys.stderr.write("TEMPLATED_JOBS " + ",".join(templated) + "\n")
    sys.exit(8)
for n in names:
    print(n)
PY
)" || {
  # The parser exits 7 (a job has no `name:`, incl. an anchor/inline job that hid from the old regex) or
  # 8 (a job name carries a ${{ }} expression that can never match a real check-run name). Either way the
  # deploy-gate allowlist sync can't trust the job set, so fail loudly and name the offending jobs above.
  echo "::error:: every job in $CI must set an explicit, literal (non-templated) \`name:\` so it is"
  echo "::error:: visible to the deploy-gate allowlist. A job that is nameless, anchor/inline-defined"
  echo "::error:: without a name, or whose name is a \${{ }} template, could run and gate deploys while"
  echo "::error:: this sync cannot see or match it. Fix the job(s) named above."
  exit 1
}

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
