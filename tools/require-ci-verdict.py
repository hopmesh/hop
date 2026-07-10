#!/usr/bin/env python3
# Deploy-gate verdict evaluator (infra-r2-02 / infra-r2-07 / infra-r2-08).
#
# Reads a GitHub "list check-runs for a ref" JSON body on stdin and the required check-run names from
# $REQUIRED (one per line), and decides whether the relay `tofu apply` may proceed for the commit.
#
# This is the SINGLE SOURCE OF TRUTH for the gate: infra/cloudbuild.trigger.yaml pipes the API body
# into it, and tools/require-ci-gate.test.sh exercises it against crafted fixtures so a regression in
# the gate logic is caught in CI (the gate itself never runs in CI, only on Cloud Build).
#
# Exit codes (consumed by the trigger's poll loop):
#   0  every required check concluded `success`         -> proceed to apply
#   2  at least one required check is pending/missing    -> keep waiting up to the budget
#   1  at least one required check FAILED (non-success)  -> refuse to deploy now
#
# Why an allowlist and not "no failures among whatever ran":
#   - infra-r2-02: a dropped/renamed/typo'd job makes its required name MISSING, which (after the
#     wait budget) fails the gate instead of silently passing on an incomplete matrix.
#   - infra-r2-07: check-runs NOT in the allowlist (e.g. the Pages deploy on a web/sim commit) are
#     ignored, so an unrelated Pages failure never blocks the relay apply.
#   - infra-r2-08: an all-skipped/neutral matrix does NOT pass; each required name must be `success`.
import sys
import json
import os


def evaluate(body_text, required):
    required = [n.strip() for n in required if n.strip()]
    runs = json.loads(body_text).get("check_runs", [])
    # For a re-run job GitHub returns multiple check-runs with the same name; keep the most recent by
    # started_at so a passing re-run supersedes an earlier failure.
    latest = {}
    for r in runs:
        n = r.get("name")
        if n not in required:
            continue
        prev = latest.get(n)
        if prev is None or (r.get("started_at") or "") >= (prev.get("started_at") or ""):
            latest[n] = r
    missing_or_pending = []
    failed = []
    for n in required:
        r = latest.get(n)
        if r is None or r.get("status") != "completed":
            missing_or_pending.append(n)
        elif r.get("conclusion") != "success":
            failed.append("%s=%s" % (n, r.get("conclusion")))
    if failed:
        return 1, "FAILED " + ", ".join(failed)
    if missing_or_pending:
        return 2, "WAIT " + ", ".join(missing_or_pending)
    return 0, "OK %d required checks green" % len(required)


def main():
    required = os.environ.get("REQUIRED", "").splitlines()
    rc, msg = evaluate(sys.stdin.read(), required)
    print(msg)
    sys.exit(rc)


if __name__ == "__main__":
    main()
