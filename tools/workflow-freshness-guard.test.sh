#!/usr/bin/env bash
# Self-test for tools/workflow-freshness-guard.py.
#
# The point of a guard's self-test in this repo is to prove the guard can FAIL, because a check that
# cannot detect its own defect is worse than no check: it manufactures confidence. So every case below
# pins a state the guard must REJECT, and only the last two pin what it must accept.
#
# The cases are the three real failure modes observed in 2026-08, plus the one that would make the guard
# itself dishonest:
#   1. the job only ever skipped              (bootstrap-apply: twelve pull_request runs, apply skipped)
#   2. the job ran, but too long ago          (runtime-deploy: nine days dead)
#   3. the API cannot be reached              (must FAIL, never pass, or the guard is decorative)
#   4. a run whose conclusion is success but whose job is null/cancelled (the green-tick illusion)
set -uo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
guard="$here/tools/workflow-freshness-guard.py"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fails=0
NOW="2026-08-16T12:00:00+00:00"

# The manifest names two workflows (sync-components and native-artifacts; runtime-deploy moved to
# hopmesh/platform). Fixtures must answer for all of them, so the builder emits a complete set and the
# case under test overrides just one.

build_fixture() {
  # $1 = path, $2 = python dict body overriding specific URL fragments
  python3 - "$1" "$2" <<'PY'
import json, sys
path, override = sys.argv[1], sys.argv[2]
base = {}
# every manifest workflow answers with one recent run whose job really succeeded. These pairs must
# match tools/workflow-freshness.json exactly: the guard reads the real manifest, so a fixture keyed
# to a workflow the manifest does not list proves nothing, and a listed workflow with no fixture
# errors out (fails closed) for the wrong reason.
for wf, job, rid in (("native-artifacts.yml", "Sign and attest native release bundle", 1),
                     ("sync-components.yml", "Auto-export changed components", 3)):
    base[f"workflows/{wf}/runs"] = {"workflow_runs": [{"id": rid, "updated_at": "2026-08-15T12:00:00Z"}]}
    base[f"runs/{rid}/jobs"] = {"jobs": [{"name": job, "conclusion": "success",
                                          "completed_at": "2026-08-15T12:00:00Z"}]}
base.update(json.loads(override))
json.dump(base, open(path, "w"))
PY
}

expect() { # $1 = label, $2 = expected rc (0 pass / 1 fail), $3 = fixture path
  out="$("$guard" --fixture "$3" --now "$NOW" 2>&1)"; rc=$?
  if [ "$rc" -eq "$2" ]; then
    printf '  ok    %-46s rc=%s\n' "$1" "$rc"
  else
    printf '  FAIL  %-46s rc=%s want=%s\n' "$1" "$rc" "$2"; printf '%s\n' "$out" | sed 's/^/          /' | head -6
    fails=$((fails+1))
  fi
}

# --- 1. the job only ever skipped: bootstrap-apply's real history -------------------------------------
# The shape is bootstrap-apply's real history: the meaningful job skipped while a cheap validate job
# succeeded, so the RUN was green. Asserted against a listed workflow because that history is exactly
# what a listed job can also do.
build_fixture "$tmp/only-skipped.json" '{
  "runs/1/jobs": {"jobs": [{"name": "Sign and attest native release bundle", "conclusion": "skipped", "completed_at": "2026-08-15T12:00:00Z"},
                            {"name": "validate", "conclusion": "success", "completed_at": "2026-08-15T12:00:00Z"}]}
}'
expect "job only ever skipped is REJECTED" 1 "$tmp/only-skipped.json"

# --- 2. ran, but outside the window: runtime-deploy's nine days ---------------------------------------
build_fixture "$tmp/stale.json" '{
  "runs/1/jobs": {"jobs": [{"name": "Sign and attest native release bundle", "conclusion": "success",
                             "completed_at": "2026-07-01T12:00:00Z"}]}
}'
expect "last real run outside window is REJECTED" 1 "$tmp/stale.json"

# --- 3. the API is unreachable: must FAIL, not pass -------------------------------------------------
build_fixture "$tmp/api-down.json" '{"workflows/native-artifacts.yml/runs": "__ERROR__"}'
expect "unreachable API is REJECTED (fails closed)" 1 "$tmp/api-down.json"

# --- 4. green run, null job conclusion: the illusion itself ------------------------------------------
build_fixture "$tmp/null-job.json" '{
  "runs/3/jobs": {"jobs": [{"name": "Auto-export changed components", "conclusion": null,
                             "completed_at": null}]}
}'
expect "null job conclusion is REJECTED" 1 "$tmp/null-job.json"

# --- 5. a malformed response must not read as fresh --------------------------------------------------
build_fixture "$tmp/malformed.json" '{"workflows/sync-components.yml/runs": {"unexpected": true}}'
expect "response missing workflow_runs is REJECTED" 1 "$tmp/malformed.json"

# --- 6. a real run inside the window passes, so the guard is not merely always-red ------------------
build_fixture "$tmp/fresh.json" '{}'
expect "all jobs fresh is ACCEPTED" 0 "$tmp/fresh.json"

# --- 7. skipped runs in FRONT of a real one still pass ----------------------------------------------
# bootstrap-apply's history is a wall of skips; the guard must look past them rather than stop at the
# first run and call it never-ran. This is the case a shallower scan would get wrong.
build_fixture "$tmp/skips-then-real.json" '{
  "workflows/sync-components.yml/runs": {"workflow_runs": [{"id": 20, "updated_at": "2026-08-15T12:00:00Z"},
                                                            {"id": 21, "updated_at": "2026-08-14T12:00:00Z"},
                                                            {"id": 3,  "updated_at": "2026-08-15T12:00:00Z"}]},
  "runs/20/jobs": {"jobs": [{"name": "Auto-export changed components", "conclusion": "skipped", "completed_at": "2026-08-15T12:00:00Z"}]},
  "runs/21/jobs": {"jobs": [{"name": "Auto-export changed components", "conclusion": "skipped", "completed_at": "2026-08-14T12:00:00Z"}]}
}'
expect "skips ahead of a real run still ACCEPTED" 0 "$tmp/skips-then-real.json"

# --- 8. the manifest itself must be non-empty and complete ------------------------------------------
python3 - <<'PY'
import json, pathlib, sys
p = pathlib.Path("tools/workflow-freshness.json")
d = json.loads(p.read_text())
assert d.get("workflows"), "manifest declares no workflows"
for e in d["workflows"]:
    for k in ("file", "job", "max_age_days", "why"):
        assert k in e, f"{e} missing {k}"
    assert pathlib.Path(".github/workflows", e["file"]).is_file(), f"{e['file']} does not exist"
    assert len(e["why"]) > 40, f"{e['file']}: 'why' must say why, not just restate the name"
    # The first version of this manifest carried windows wider than the outages they were written for
    # (14d for a 9d outage, 120d for a 25d drift), which would have stayed green throughout. Every job
    # listed here fires on every merge to main, and this repo merges at least daily, so a window above
    # a few missed merges cannot detect anything and must not be added back.
    assert e["max_age_days"] <= 7, (
        f"{e['file']}: max_age_days={e['max_age_days']} is wider than the cadence it claims to police; "
        "a window bigger than the outage is decoration"
    )
print("  ok    manifest is complete, files exist, windows are tight enough to catch something")
PY
[ $? -eq 0 ] || fails=$((fails+1))

if [ "$fails" -ne 0 ]; then
  echo "workflow-freshness-guard.test: $fails case(s) FAILED"
  exit 1
fi
echo "workflow-freshness-guard.test: all cases passed"
