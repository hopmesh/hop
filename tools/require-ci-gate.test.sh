#!/usr/bin/env bash
# Regression test for the deploy gate verdict (tools/require-ci-verdict.py), covering
# infra-r2-02 (required-name allowlist), infra-r2-07 (ignore non-required check-runs), and
# infra-r2-08 (all-skipped/neutral is NOT green).
#
# Each case feeds a crafted GitHub check-runs body on stdin and asserts the exit code:
#   0 = proceed, 1 = fail (refuse), 2 = wait.
#
# BEFORE THE FIX these would have behaved wrongly: the old aggregate counted `skipped`/`neutral` as
# non-failures and passed when `pending==0 and total>0`, so an all-skipped matrix (case: all_skipped),
# a matrix missing a required job (case: missing_required), and a run where an unrelated Pages check
# failed (case: pages_fail_ignored) all decided WRONG. This suite pins the corrected behavior.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
EVAL="$HERE/require-ci-verdict.py"

# The 9 required checks, mirroring _REQUIRED_CHECKS in infra/cloudbuild.trigger.yaml.
REQ="Rust (test · clippy · fmt)
Kotlin SDK tests (BearerManager)
Android bearers + driver (JVM unit tests)
Apple bearers + driver + app (build-only)
WASM sim (wasm32 build + swarm invariants)
Web + sim (Astro build · scenario-check · link check)
Contract purity + header drift + C smoke
Terraform (fmt · validate · plan)
Docs token guard (banned copy)"

fails=0

# run <case-name> <expected-rc> <body-json>
run() {
  local name="$1" want="$2" body="$3"
  printf '%s' "$body" | REQUIRED="$REQ" python3 "$EVAL" >/tmp/rcgate.out 2>&1
  local got=$?
  if [ "$got" != "$want" ]; then
    echo "FAIL [$name]: expected rc=$want got rc=$got ($(cat /tmp/rcgate.out))"
    fails=$((fails + 1))
  else
    echo "ok   [$name]: rc=$got ($(cat /tmp/rcgate.out))"
  fi
}

# Emit a check-runs JSON body from "name|status|conclusion" triples (one per arg), plus optional extras.
mk() {
  python3 - "$@" <<'PY'
import sys, json
runs = []
for spec in sys.argv[1:]:
    name, status, concl = spec.split("|")
    runs.append({"name": name, "status": status,
                 "conclusion": (concl or None), "started_at": "2026-01-01T00:00:00Z"})
print(json.dumps({"total_count": len(runs), "check_runs": runs}))
PY
}

# The 9 required names, as an array, for building bodies.
NAMES=(
  "Rust (test · clippy · fmt)"
  "Kotlin SDK tests (BearerManager)"
  "Android bearers + driver (JVM unit tests)"
  "Apple bearers + driver + app (build-only)"
  "WASM sim (wasm32 build + swarm invariants)"
  "Web + sim (Astro build · scenario-check · link check)"
  "Contract purity + header drift + C smoke"
  "Terraform (fmt · validate · plan)"
  "Docs token guard (banned copy)"
)

all_success() { local a=(); for n in "${NAMES[@]}"; do a+=("$n|completed|success"); done; mk "${a[@]}"; }
all_skipped() { local a=(); for n in "${NAMES[@]}"; do a+=("$n|completed|skipped"); done; mk "${a[@]}"; }

# --- happy path: every required check green -> proceed (0) ---
run "all_success" 0 "$(all_success)"

# --- infra-r2-08: all-skipped/neutral is NOT green -> refuse (1) (old gate wrongly passed this) ---
run "all_skipped" 1 "$(all_skipped)"

# --- one required check failed -> refuse (1) ---
{
  a=(); for n in "${NAMES[@]}"; do a+=("$n|completed|success"); done
  a[0]="${NAMES[0]}|completed|failure"
  BODY_FAIL="$(mk "${a[@]}")"
}
run "one_failed" 1 "$BODY_FAIL"

# --- one required check still running -> wait (2) ---
{
  a=(); for n in "${NAMES[@]}"; do a+=("$n|completed|success"); done
  a[3]="${NAMES[3]}|in_progress|"
  BODY_PENDING="$(mk "${a[@]}")"
}
run "one_pending" 2 "$BODY_PENDING"

# --- infra-r2-02: a required job MISSING (dropped/renamed) -> wait then fail (2 here) ---
# (old gate passed because it only checked "no failures among whatever ran")
{
  a=(); for n in "${NAMES[@]:0:8}"; do a+=("$n|completed|success"); done  # drop the 9th
  BODY_MISSING="$(mk "${a[@]}")"
}
run "missing_required" 2 "$BODY_MISSING"

# --- infra-r2-07: an unrelated (non-required) check-run that FAILED is IGNORED -> proceed (0) ---
# (models a Pages deploy failing on a web/sim commit; must not block the relay apply)
{
  a=(); for n in "${NAMES[@]}"; do a+=("$n|completed|success"); done
  a+=("deploy (Deploy marketing site (Pages))|completed|failure")
  BODY_PAGES="$(mk "${a[@]}")"
}
run "pages_fail_ignored" 0 "$BODY_PAGES"

# --- re-run supersedes: an earlier failed run + a later success for the same name -> proceed (0) ---
{
  a=(); for n in "${NAMES[@]:1}"; do a+=("$n|completed|success"); done
  BODY_RERUN="$(python3 - "${NAMES[0]}" "$(mk "${a[@]}")" <<'PY'
import sys, json
name = sys.argv[1]
base = json.loads(sys.argv[2])
base["check_runs"].append({"name": name, "status": "completed", "conclusion": "failure", "started_at": "2026-01-01T00:00:00Z"})
base["check_runs"].append({"name": name, "status": "completed", "conclusion": "success", "started_at": "2026-01-01T01:00:00Z"})
print(json.dumps(base))
PY
)"
}
run "rerun_supersedes" 0 "$BODY_RERUN"

echo
if [ "$fails" -eq 0 ]; then
  echo "require-ci gate: all cases passed"
else
  echo "require-ci gate: $fails case(s) FAILED"
  exit 1
fi
