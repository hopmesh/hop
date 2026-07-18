#!/usr/bin/env bash
# quality-net-r2-03: assert the LIVE GitHub branch-protection rule on `main` requires exactly the single
# aggregate `CI gate` check, so the deploy gate's intent half can't silently drift (protection turned
# off, or the required check swapped away from the gate).
#
# In the aggregate-gate model the ONE required context is `CI gate` (its Actions check-run context is
# the job name verbatim, NOT "<workflow> / <job>"). The per-job integrity (the gate `needs:` every job,
# _REQUIRED_CHECKS == [CI gate]) is enforced separately by check-required-checks.sh in the PR gate; here
# we only assert the live rule requires the gate and nothing else. Fails on any mismatch, on protection
# being absent, or on an API error (so a missing/insufficient token surfaces as a red audit, not a false
# green).
#
# Env:
#   GH_TOKEN  a token that can read branch protection (administration:read) on the repo.
#   GH_REPO   owner/name (defaults to hopmesh/hop).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CI="$ROOT/.github/workflows/ci.yml"
REPO="${GH_REPO:-hopmesh/hop}"

if [ -z "${GH_TOKEN:-}" ]; then
  echo "::error:: GH_TOKEN not set; cannot read branch protection for $REPO"; exit 1
fi

# Expected context: exactly the single `CI gate` check. Confirm ci.yml actually defines that job (skip
# comment lines; ":(\s|$)" so an anchor/inline job is still a boundary, matching check-required-checks.sh)
# so a rename of the gate here surfaces as a config error rather than a silently-empty expectation.
expected="$(python3 - "$CI" <<'PY'
import sys, re
ci = sys.argv[1]
in_jobs = False
pending = False
found = False
for line in open(ci):
    if re.match(r'^jobs:\s*$', line):
        in_jobs = True; continue
    if not in_jobs:
        continue
    if line.lstrip().startswith('#'):
        continue
    if re.match(r'^  (\S[^:]*):(\s|$)', line):
        pending = True; continue
    m = re.match(r'^    name:\s*(.+?)\s*$', line)
    if m and pending:
        if m.group(1) == "CI gate":
            found = True
        pending = False
if found:
    print("CI gate")
PY
)"
if [ -z "$expected" ]; then
  echo "::error:: ci.yml defines no 'CI gate' job; the aggregate-gate branch-protection model expects one"; exit 1
fi

api="https://api.github.com/repos/${REPO}/branches/main/protection"
# -L follows the 301 GitHub returns when the repo has been renamed (repos/<owner>/<oldname> ->
# repositories/<id>); without it a renamed repo reads as an "unexpected HTTP 301" and reddens the audit.
resp="$(curl -sSL -w '\n%{http_code}' \
  -H "Authorization: Bearer $GH_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "$api")"
code="$(printf '%s' "$resp" | tail -n1)"
body="$(printf '%s' "$resp" | sed '$d')"

if [ "$code" = "404" ]; then
  echo "::error:: branch 'main' has NO protection rule (or it is not visible to this token)."
  echo "  Set protection so 'Require status checks to pass' includes the 'CI gate' check (see infra/README.md)."
  exit 1
fi
if [ "$code" = "403" ] || [ "$code" = "401" ]; then
  echo "::error:: HTTP $code reading branch protection for $REPO."
  echo "  The token lacks 'administration:read'. Set the BRANCH_PROTECTION_TOKEN secret (PAT/app token)."
  exit 1
fi
if [ "$code" != "200" ]; then
  echo "::error:: unexpected HTTP $code from $api"; echo "$body" | head -5; exit 1
fi

# Live required contexts (support both the modern checks[].context and legacy contexts[]).
actual="$(printf '%s' "$body" | python3 -c '
import sys, json
d = json.load(sys.stdin)
rsc = d.get("required_status_checks") or {}
ctx = set()
for c in rsc.get("checks", []) or []:
    if c.get("context"): ctx.add(c["context"])
for c in rsc.get("contexts", []) or []:
    ctx.add(c)
for c in sorted(ctx):
    print(c)
')"

if [ -z "$actual" ]; then
  echo "::error:: main protection exists but requires NO status checks. A red commit can land."
  echo "  Add the 'CI gate' check to 'Require status checks to pass'."
  exit 1
fi

exp_sorted="$(printf '%s\n' "$expected" | sort)"
act_sorted="$(printf '%s\n' "$actual" | sort)"

missing="$(comm -23 <(printf '%s\n' "$exp_sorted") <(printf '%s\n' "$act_sorted") || true)"
extra="$(comm -13 <(printf '%s\n' "$exp_sorted") <(printf '%s\n' "$act_sorted") || true)"

fail=0
if [ -n "$missing" ]; then
  echo "::error:: main is NOT requiring these CI checks (a failing one could land):"
  while IFS= read -r check; do
    printf '  - %s\n' "$check"
  done <<< "$missing"
  fail=1
fi
if [ -n "$extra" ]; then
  echo "::error:: main requires status checks not produced by ci.yml (stale name?):"
  while IFS= read -r check; do
    printf '  - %s\n' "$check"
  done <<< "$extra"
  fail=1
fi
if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "branch protection on main requires exactly the single CI gate check"
