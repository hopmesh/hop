#!/usr/bin/env bash
# quality-net-r2-03: assert the LIVE GitHub branch-protection rule on `main` requires exactly the CI
# checks, so the deploy gate's intent half can't silently drift (a renamed job, protection turned off).
#
# Compares the required status-check contexts on main against the ci.yml job names. For GitHub Actions
# checks, the required-status-check context IS the job name verbatim (e.g. "Rust (test . clippy . fmt)"),
# NOT "<workflow> / <job>". Verified against the live rule + the commit check-runs. Fails on any
# mismatch, on protection being absent, or on an API error (so a missing/insufficient token surfaces
# as a red audit rather than a false green).
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

# Expected contexts: the job name verbatim for every job in ci.yml (the Actions check-run name that
# branch protection matches against).
expected="$(python3 - "$CI" <<'PY'
import sys, re
ci = sys.argv[1]
in_jobs = False
job_pending = False
for line in open(ci):
    if re.match(r'^jobs:\s*$', line):
        in_jobs = True; continue
    if not in_jobs:
        continue
    # ":(\s|$)" (not ":\s*$") so an anchor/inline-defined job is still seen as a job boundary (F-CI-2),
    # matching check-required-checks.sh. This script only emits names for the comparison; the
    # nameless/templated hard-fail lives in check-required-checks.sh, which the audit runs first.
    if re.match(r'^  (\S[^:]*):(\s|$)', line):
        job_pending = True; continue
    m = re.match(r'^    name:\s*(.+?)\s*$', line)
    if m and job_pending:
        print(m.group(1))
        job_pending = False
PY
)"
if [ -z "$expected" ]; then
  echo "::error:: could not parse job names from $CI"; exit 1
fi

api="https://api.github.com/repos/${REPO}/branches/main/protection"
resp="$(curl -sS -w '\n%{http_code}' \
  -H "Authorization: Bearer $GH_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "$api")"
code="$(printf '%s' "$resp" | tail -n1)"
body="$(printf '%s' "$resp" | sed '$d')"

if [ "$code" = "404" ]; then
  echo "::error:: branch 'main' has NO protection rule (or it is not visible to this token)."
  echo "  Set protection so 'Require status checks to pass' includes every ci.yml job-name context (see infra/README.md)."
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
  echo "  Add every ci.yml job-name context to 'Require status checks to pass'."
  exit 1
fi

exp_sorted="$(printf '%s\n' "$expected" | sort)"
act_sorted="$(printf '%s\n' "$actual" | sort)"

missing="$(comm -23 <(printf '%s\n' "$exp_sorted") <(printf '%s\n' "$act_sorted") || true)"
extra="$(comm -13 <(printf '%s\n' "$exp_sorted") <(printf '%s\n' "$act_sorted") || true)"

fail=0
if [ -n "$missing" ]; then
  echo "::error:: main is NOT requiring these CI checks (a failing one could land):"
  printf '  - %s\n' $missing
  fail=1
fi
if [ -n "$extra" ]; then
  echo "::warning:: main requires status checks not produced by ci.yml (stale name?):"
  printf '  - %s\n' $extra
fi
if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "branch protection on main requires all $(printf '%s\n' "$expected" | grep -c .) CI checks"
