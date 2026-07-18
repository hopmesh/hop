#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"

python3 - "$root/tools/require-ci-verdict.py" <<'PY'
import copy
import base64
import hashlib
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("verdict", sys.argv[1])
verdict = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verdict)

SHA = "a" * 40
REPO = "hopmesh/hop"
REPO_ID = 101
APP_ID = 15368
WORKFLOW_ID = 202
WORKFLOW_BODY = b"name: CI\non: [push]\njobs: {}\n"
WORKFLOW_SHA256 = hashlib.sha256(WORKFLOW_BODY).hexdigest()
CHECKS = [
    "Detect changed areas",
    "Rust (test \u00b7 clippy \u00b7 fmt)",
    "Kotlin SDK tests (BearerManager)",
    "Android bearers + driver (JVM unit tests)",
    "Apple bearers + driver + app (build-only)",
    "WASM sim (wasm32 build + swarm invariants)",
    "Web + sim (Astro build \u00b7 scenario-check \u00b7 link check)",
    "Contract purity + header drift + C smoke",
    "Terraform (fmt \u00b7 validate \u00b7 plan)",
    "Automation authority guards",
    "Docs token guard (banned copy)",
    "Node endpoint SDK (proofs)",
    "Python endpoint SDK (proofs)",
    "Go endpoint SDK (race)",
    "Ruby endpoint SDK (proofs)",
    "Crystal endpoint SDK (spec)",
    "Elixir endpoint SDK (mix test)",
    "CI gate",
]


def expected():
    return {
        "repository": REPO,
        "repository_id": REPO_ID,
        "actions_app_id": APP_ID,
        "canonical_ref": "refs/heads/main",
        "workflows": [{
            "id": WORKFLOW_ID,
            "path": ".github/workflows/ci.yml",
            "checks": list(CHECKS),
            "sha256": WORKFLOW_SHA256,
        }],
    }


def repository():
    return {"id": REPO_ID, "full_name": REPO, "default_branch": "main"}


def run(attempt=1):
    return {
        "id": 303,
        "workflow_id": WORKFLOW_ID,
        "path": ".github/workflows/ci.yml",
        "event": "push",
        "head_branch": "main",
        "head_sha": SHA,
        "run_attempt": attempt,
        "status": "completed",
        "conclusion": "success",
        "check_suite_id": 404,
        "workflow_url": f"https://api.github.com/repos/{REPO}/actions/workflows/{WORKFLOW_ID}",
        "check_suite_url": f"https://api.github.com/repos/{REPO}/check-suites/404",
        "repository": repository(),
        "head_repository": repository(),
    }


def suite():
    return {
        "id": 404,
        "head_sha": SHA,
        "head_branch": "main",
        "status": "completed",
        "conclusion": "success",
        "latest_check_runs_count": len(CHECKS),
        "app": {"id": APP_ID},
        "repository": repository(),
    }


def workflow_file(body=WORKFLOW_BODY):
    encoded = base64.b64encode(body).decode("ascii")
    return {
        "type": "file",
        "path": ".github/workflows/ci.yml",
        "encoding": "base64",
        "size": len(body),
        "content": "\n".join(encoded[index:index + 60] for index in range(0, len(encoded), 60)),
    }


def jobs(attempt=1, conclusions=None):
    conclusions = conclusions or {}
    values = []
    for index, name in enumerate(CHECKS):
        values.append({
            "id": 500 + index,
            "name": name,
            "head_sha": SHA,
            "run_attempt": attempt,
            "status": "completed",
            "conclusion": conclusions.get(name, "success"),
            "check_run_url": f"https://api.github.com/repos/{REPO}/check-runs/{500 + index}",
        })
    return {"total_count": len(values), "jobs": values}


def snapshot(attempt=1):
    return {
        "repository": repository(),
        "canonical_ref": {"ref": "refs/heads/main", "object": {"type": "commit", "sha": SHA}},
        "workflows": [{
            "workflow_id": WORKFLOW_ID,
            "workflow_file": workflow_file(),
            "runs": {"total_count": 1, "workflow_runs": [run(attempt)]},
            "check_suite": suite(),
            "jobs": jobs(attempt),
        }],
    }


def check(name, want, mutate=None, expected_mutate=None, source_sha=SHA):
    snap = snapshot()
    config = expected()
    if mutate:
        mutate(snap)
    if expected_mutate:
        expected_mutate(config)
    got, message = verdict.evaluate(snap, config, source_sha)
    if got != want:
        raise AssertionError(f"{name}: expected {want}, got {got}: {message}")
    print(f"ok [{name}] rc={got}: {message}")


check("all_success", 0)
check(
    "production_path_filtered_skips_with_green_aggregate",
    0,
    lambda s: [
        job.__setitem__("conclusion", "skipped")
        for job in s["workflows"][0]["jobs"]["jobs"]
        if job["name"] in {"Apple bearers + driver + app (build-only)", "Go endpoint SDK (race)"}
    ],
)
check("forged_display_name", 1, lambda s: s["workflows"][0]["jobs"]["jobs"].__setitem__(0, {**s["workflows"][0]["jobs"]["jobs"][0], "name": "Forged CI"}))
check("wrong_actions_app", 1, lambda s: s["workflows"][0]["check_suite"]["app"].__setitem__("id", 999))
check("wrong_workflow_id", 1, lambda s: s["workflows"][0]["runs"]["workflow_runs"][0].__setitem__("workflow_id", 999))
check("wrong_workflow_path", 1, lambda s: s["workflows"][0]["runs"]["workflow_runs"][0].__setitem__("path", ".github/workflows/forged.yml"))
check("wrong_event", 1, lambda s: s["workflows"][0]["runs"]["workflow_runs"][0].__setitem__("event", "pull_request"))
check("wrong_ref", 1, lambda s: s["canonical_ref"].__setitem__("ref", "refs/heads/release"))
check("wrong_branch", 1, lambda s: s["workflows"][0]["runs"]["workflow_runs"][0].__setitem__("head_branch", "feature"))
check("wrong_sha", 1, lambda s: s["workflows"][0]["runs"]["workflow_runs"][0].__setitem__("head_sha", "b" * 40))
check("stale_main", 1, lambda s: s["canonical_ref"]["object"].__setitem__("sha", "b" * 40))
check("wrong_repository", 1, lambda s: s["repository"].__setitem__("id", 999))
check("empty_workflows", 1, expected_mutate=lambda e: e.__setitem__("workflows", []))
check("empty_checks", 1, expected_mutate=lambda e: e["workflows"][0].__setitem__("checks", []))
check("duplicate_checks", 1, expected_mutate=lambda e: e["workflows"][0].__setitem__("checks", [CHECKS[0], CHECKS[0]]))
check("duplicate_runs", 1, lambda s: (s["workflows"][0]["runs"].__setitem__("total_count", 2), s["workflows"][0]["runs"]["workflow_runs"].append(copy.deepcopy(s["workflows"][0]["runs"]["workflow_runs"][0]))))
check("duplicate_jobs", 1, lambda s: (s["workflows"][0]["jobs"].__setitem__("total_count", len(CHECKS) + 1), s["workflows"][0]["jobs"]["jobs"].append(copy.deepcopy(s["workflows"][0]["jobs"]["jobs"][0])), s["workflows"][0]["check_suite"].__setitem__("latest_check_runs_count", len(CHECKS) + 1)))
check("incomplete_jobs_api", 1, lambda s: s["workflows"][0]["jobs"].__setitem__("total_count", len(CHECKS) + 1))
check("missing_job", 1, lambda s: (s["workflows"][0]["jobs"]["jobs"].pop(), s["workflows"][0]["jobs"].__setitem__("total_count", len(CHECKS) - 1), s["workflows"][0]["check_suite"].__setitem__("latest_check_runs_count", len(CHECKS) - 1)))
check("unexpected_extra_job", 1, lambda s: (s["workflows"][0]["jobs"]["jobs"].append({**s["workflows"][0]["jobs"]["jobs"][1], "id": 999, "name": "Untrusted extra"}), s["workflows"][0]["jobs"].__setitem__("total_count", len(CHECKS) + 1), s["workflows"][0]["check_suite"].__setitem__("latest_check_runs_count", len(CHECKS) + 1)))
check("pending_run", 2, lambda s: (s["workflows"][0]["runs"]["workflow_runs"][0].__setitem__("status", "in_progress"), s["workflows"][0]["runs"]["workflow_runs"][0].__setitem__("conclusion", None)))
check("failed_run", 1, lambda s: s["workflows"][0]["runs"]["workflow_runs"][0].__setitem__("conclusion", "failure"))
check("missing_run", 2, lambda s: (s["workflows"][0]["runs"].__setitem__("total_count", 0), s["workflows"][0]["runs"].__setitem__("workflow_runs", [])))
check("stale_job_attempt", 1, lambda s: s["workflows"][0]["jobs"]["jobs"][0].__setitem__("run_attempt", 2))
check("cancelled_product_job", 1, lambda s: s["workflows"][0]["jobs"]["jobs"][1].__setitem__("conclusion", "cancelled"))
check("failed_product_job", 1, lambda s: s["workflows"][0]["jobs"]["jobs"][1].__setitem__("conclusion", "failure"))
check("skipped_change_detector", 1, lambda s: s["workflows"][0]["jobs"]["jobs"][0].__setitem__("conclusion", "skipped"))
check("skipped_automation_guards", 1, lambda s: next(job for job in s["workflows"][0]["jobs"]["jobs"] if job["name"] == "Automation authority guards").__setitem__("conclusion", "skipped"))
check("skipped_aggregate_gate", 1, lambda s: s["workflows"][0]["jobs"]["jobs"][-1].__setitem__("conclusion", "skipped"))
check("changed_workflow_body", 1, lambda s: s["workflows"][0].__setitem__("workflow_file", workflow_file(WORKFLOW_BODY + b"# changed\n")))
check("bootstrap_digest_mismatch", 1, expected_mutate=lambda e: e["workflows"][0].__setitem__("sha256", "0" * 64))

rerun_snapshot = snapshot(attempt=2)
rc, message = verdict.evaluate(rerun_snapshot, expected(), SHA)
if rc != 0:
    raise AssertionError(f"current rerun attempt was rejected: {message}")
print(f"ok [rerun_current_attempt] rc={rc}: {message}")

for bad_sha in ("", "abc1234", "A" * 40, "a" * 39, "a" * 41):
    rc, message = verdict.evaluate(snapshot(), expected(), bad_sha)
    if rc != 1:
        raise AssertionError(f"full SHA enforcement accepted {bad_sha!r}: {message}")
print("ok [full_sha_enforcement]")

class TransientClient:
    def get(self, _path):
        raise verdict.TransientAPIError("temporary GitHub outage")

if verdict.canonical_once(TransientClient(), expected(), SHA) != 1:
    raise AssertionError("canonical check accepted a transient GitHub failure")
print("ok [canonical_transient_failure_is_recordable]")

if verdict.trusted_environment_main("unknown") != 1:
    raise AssertionError("trusted gate accepted an unknown execution mode")
print("ok [unknown_trusted_mode_rejected]")
PY

echo "require-ci gate tests passed"
