#!/usr/bin/env python3
"""Validate the exact GitHub Actions verdict used by the deployment gate."""

import argparse
import base64
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


SHA_RE = re.compile(r"^[0-9a-f]{40}\Z")
SHA256_RE = re.compile(r"^[0-9a-f]{64}\Z")
REPOSITORY_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\Z")
ALWAYS_SUCCESS_JOBS = {
    "Detect changed areas",
    "Automation authority guards",
    "CI gate",
}
TERMINAL_FAILURES = {
    "action_required",
    "cancelled",
    "failure",
    "neutral",
    "skipped",
    "stale",
    "startup_failure",
    "timed_out",
}


class GateError(RuntimeError):
    """A permanent, fail-closed gate error."""


class TransientAPIError(RuntimeError):
    """A retryable transport or upstream error."""


def _require(condition, message):
    if not condition:
        raise GateError(message)


def _positive_int(value):
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def validate_expected(expected, source_sha):
    _require(isinstance(expected, dict), "expected configuration must be an object")
    _require(SHA_RE.fullmatch(source_sha or ""), "source SHA must be exactly 40 lowercase hexadecimal characters")

    repository = expected.get("repository")
    _require(isinstance(repository, str) and REPOSITORY_RE.fullmatch(repository), "repository must be owner/name")
    _require(_positive_int(expected.get("repository_id")), "repository_id must be a positive integer")
    _require(_positive_int(expected.get("actions_app_id")), "actions_app_id must be a positive integer")
    _require(expected.get("canonical_ref") == "refs/heads/main", "canonical_ref must be refs/heads/main")

    workflows = expected.get("workflows")
    _require(isinstance(workflows, list) and workflows, "at least one expected workflow is required")
    workflow_ids = []
    workflow_paths = []
    all_checks = []
    normalized = []
    for workflow in workflows:
        _require(isinstance(workflow, dict), "each expected workflow must be an object")
        workflow_id = workflow.get("id")
        path = workflow.get("path")
        checks = workflow.get("checks")
        digest = workflow.get("sha256")
        _require(_positive_int(workflow_id), "workflow id must be a positive integer")
        _require(
            isinstance(path, str)
            and path.startswith(".github/workflows/")
            and path.endswith((".yml", ".yaml")),
            "workflow path must name a workflow file",
        )
        _require(isinstance(checks, list) and checks, f"workflow {path} must require at least one check")
        _require(
            isinstance(digest, str) and SHA256_RE.fullmatch(digest),
            f"workflow {path} must bind an exact SHA-256 digest",
        )
        clean_checks = []
        for check in checks:
            _require(isinstance(check, str) and check == check.strip() and check, "check names must be non-empty and trimmed")
            clean_checks.append(check)
        _require(len(clean_checks) == len(set(clean_checks)), f"workflow {path} contains duplicate required checks")
        _require(
            ALWAYS_SUCCESS_JOBS.issubset(clean_checks),
            f"workflow {path} must include every always-success job",
        )
        workflow_ids.append(workflow_id)
        workflow_paths.append(path)
        all_checks.extend(clean_checks)
        normalized.append({"id": workflow_id, "path": path, "checks": clean_checks, "sha256": digest})

    _require(len(workflow_ids) == len(set(workflow_ids)), "expected workflow ids must be unique")
    _require(len(workflow_paths) == len(set(workflow_paths)), "expected workflow paths must be unique")
    _require(len(all_checks) == len(set(all_checks)), "required check names must be unique across workflows")
    return {
        "repository": repository,
        "repository_id": expected["repository_id"],
        "actions_app_id": expected["actions_app_id"],
        "canonical_ref": expected["canonical_ref"],
        "workflows": normalized,
        "source_sha": source_sha,
    }


def _validate_repository(value, expected):
    _require(isinstance(value, dict), "repository API response is missing")
    _require(value.get("id") == expected["repository_id"], "repository id does not match the trusted configuration")
    _require(value.get("full_name") == expected["repository"], "repository name does not match the trusted configuration")
    _require(value.get("default_branch") == "main", "repository default branch is not canonical main")


def _validate_nested_repository(value, expected, label):
    _require(isinstance(value, dict), f"{label} repository metadata is missing")
    _require(value.get("id") == expected["repository_id"], f"{label} repository id is wrong")
    _require(value.get("full_name") == expected["repository"], f"{label} repository name is wrong")


def _validate_ref(value, expected):
    _require(isinstance(value, dict), "canonical ref API response is missing")
    _require(value.get("ref") == expected["canonical_ref"], "canonical ref is wrong")
    target = value.get("object")
    _require(isinstance(target, dict), "canonical ref target is missing")
    _require(target.get("type") == "commit", "canonical main does not point to a commit")
    _require(target.get("sha") == expected["source_sha"], "source SHA is no longer canonical main")


def _validate_complete_collection(value, collection_key, label):
    _require(isinstance(value, dict), f"{label} API response is missing")
    items = value.get(collection_key)
    total = value.get("total_count")
    _require(isinstance(items, list), f"{label} list is missing")
    _require(isinstance(total, int) and not isinstance(total, bool), f"{label} total_count is missing")
    _require(total == len(items), f"{label} response is incomplete or paginated")
    _require(total <= 100, f"{label} response exceeds the trusted single-page bound")
    return items


def _validate_run(run, workflow, expected):
    _require(isinstance(run, dict), "workflow run entry is malformed")
    _require(_positive_int(run.get("id")), "workflow run id is missing")
    _require(run.get("workflow_id") == workflow["id"], "workflow run id does not match the trusted workflow")
    _require(run.get("path") == workflow["path"], "workflow run path does not match the trusted workflow")
    _require(run.get("event") == "push", "workflow run event is not push")
    _require(run.get("head_branch") == "main", "workflow run branch is not canonical main")
    _require(run.get("head_sha") == expected["source_sha"], "workflow run head SHA is wrong")
    _require(_positive_int(run.get("run_attempt")), "workflow run attempt is missing")
    _validate_nested_repository(run.get("repository"), expected, "workflow run")
    _validate_nested_repository(run.get("head_repository"), expected, "workflow head")
    _require(_positive_int(run.get("check_suite_id")), "workflow check suite id is missing")
    expected_workflow_url = f"https://api.github.com/repos/{expected['repository']}/actions/workflows/{workflow['id']}"
    _require(run.get("workflow_url") == expected_workflow_url, "workflow API identity is wrong")


def _validate_workflow_file(value, workflow):
    _require(isinstance(value, dict), "workflow contents API response is missing")
    _require(value.get("type") == "file", "trusted workflow path is not a regular file")
    _require(value.get("path") == workflow["path"], "workflow contents path is wrong")
    _require(value.get("encoding") == "base64", "workflow contents encoding is not base64")
    encoded = value.get("content")
    _require(isinstance(encoded, str) and encoded, "workflow contents are missing")
    try:
        body = base64.b64decode(encoded.replace("\n", "").replace("\r", ""), validate=True)
    except (TypeError, ValueError) as error:
        raise GateError("workflow contents are not valid base64") from error
    _require(value.get("size") == len(body), "workflow contents size is wrong")
    _require(
        hashlib.sha256(body).hexdigest() == workflow["sha256"],
        "workflow contents do not match the bootstrap-owned digest",
    )


def _validate_suite(suite, run, expected):
    _require(isinstance(suite, dict), "check suite API response is missing")
    _require(suite.get("id") == run["check_suite_id"], "check suite id does not match the workflow run")
    _require(suite.get("head_sha") == expected["source_sha"], "check suite head SHA is wrong")
    _require(suite.get("head_branch") == "main", "check suite head branch is wrong")
    _require(suite.get("status") == "completed", "successful workflow has an incomplete check suite")
    _require(suite.get("conclusion") == "success", "check suite did not conclude success")
    app = suite.get("app")
    _require(isinstance(app, dict) and app.get("id") == expected["actions_app_id"], "check suite was not created by the trusted GitHub Actions App")
    _validate_nested_repository(suite.get("repository"), expected, "check suite")
    _require(
        isinstance(suite.get("latest_check_runs_count"), int),
        "check suite latest_check_runs_count is missing",
    )


def _validate_jobs(jobs_response, workflow, run, suite, expected):
    jobs = _validate_complete_collection(jobs_response, "jobs", "workflow jobs")
    _require(suite["latest_check_runs_count"] == len(jobs), "check suite and workflow jobs disagree")
    expected_names = workflow["checks"]
    expected_set = set(expected_names)
    by_name = {}
    for job in jobs:
        _require(isinstance(job, dict), "workflow job entry is malformed")
        name = job.get("name")
        _require(isinstance(name, str) and name, "workflow job name is missing")
        _require(name in expected_set, f"unexpected workflow job: {name}")
        _require(name not in by_name, f"duplicate workflow job: {name}")
        _require(job.get("head_sha") == expected["source_sha"], f"job {name} has the wrong head SHA")
        _require(job.get("run_attempt") == run["run_attempt"], f"job {name} belongs to a stale run attempt")
        check_run_url = job.get("check_run_url")
        _require(
            isinstance(check_run_url, str)
            and check_run_url.startswith(f"https://api.github.com/repos/{expected['repository']}/check-runs/"),
            f"job {name} check-run identity is wrong",
        )
        by_name[name] = job

    missing = [name for name in expected_names if name not in by_name]
    _require(not missing, "completed workflow is missing required jobs: " + ", ".join(missing))
    failed = []
    pending = []
    for name in expected_names:
        job = by_name[name]
        status = job.get("status")
        conclusion = job.get("conclusion")
        if status != "completed":
            pending.append(name)
        elif name in ALWAYS_SUCCESS_JOBS and conclusion != "success":
            failed.append(f"{name}={conclusion}")
        elif name not in ALWAYS_SUCCESS_JOBS and conclusion not in {"success", "skipped"}:
            failed.append(f"{name}={conclusion}")
    if failed:
        raise GateError("required workflow jobs failed: " + ", ".join(failed))
    if pending:
        return 2, "WAIT jobs pending: " + ", ".join(pending)
    return 0, f"OK {len(expected_names)} trusted jobs green"


def evaluate(snapshot, expected_config, source_sha):
    """Return (0, message), (1, message), or (2, message) for one API snapshot."""
    try:
        expected = validate_expected(expected_config, source_sha)
        _require(isinstance(snapshot, dict), "gate snapshot must be an object")
        _validate_repository(snapshot.get("repository"), expected)
        _validate_ref(snapshot.get("canonical_ref"), expected)
        snapshots = snapshot.get("workflows")
        _require(isinstance(snapshots, list), "workflow snapshots are missing")
        _require(len(snapshots) == len(expected["workflows"]), "workflow snapshot count is wrong")

        messages = []
        for workflow, workflow_snapshot in zip(expected["workflows"], snapshots):
            _require(isinstance(workflow_snapshot, dict), "workflow snapshot is malformed")
            _require(workflow_snapshot.get("workflow_id") == workflow["id"], "workflow snapshot id is wrong")
            _validate_workflow_file(workflow_snapshot.get("workflow_file"), workflow)
            runs = _validate_complete_collection(workflow_snapshot.get("runs"), "workflow_runs", "workflow runs")
            if not runs:
                return 2, f"WAIT workflow {workflow['path']} has not started"
            _require(len(runs) == 1, f"workflow {workflow['path']} has ambiguous duplicate runs")
            run = runs[0]
            _validate_run(run, workflow, expected)
            status = run.get("status")
            conclusion = run.get("conclusion")
            if status != "completed":
                _require(status in {"queued", "in_progress", "pending", "requested", "waiting"}, "workflow run status is invalid")
                return 2, f"WAIT workflow {workflow['path']} is {status}"
            _require(conclusion is not None, "completed workflow run has no conclusion")
            if conclusion != "success":
                _require(conclusion in TERMINAL_FAILURES, "workflow run conclusion is invalid")
                raise GateError(f"workflow {workflow['path']} concluded {conclusion}")
            suite = workflow_snapshot.get("check_suite")
            _validate_suite(suite, run, expected)
            rc, message = _validate_jobs(workflow_snapshot.get("jobs"), workflow, run, suite, expected)
            if rc:
                return rc, message
            messages.append(message)
        return 0, "; ".join(messages)
    except GateError as error:
        return 1, f"FAIL {error}"


class GitHubClient:
    def __init__(self, repository, token):
        self.repository = repository
        self.base = f"https://api.github.com/repos/{repository}"
        self.token = token

    def get(self, path, query=None):
        if path.startswith("https://"):
            _require(path.startswith(self.base + "/"), "GitHub API URL escaped the trusted repository")
            url = path
        else:
            url = self.base + path
        if query:
            url += "?" + urllib.parse.urlencode(query)
        request = urllib.request.Request(
            url,
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {self.token}",
                "User-Agent": "hop-trusted-deploy-gate/1",
                "X-GitHub-Api-Version": "2022-11-28",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                if response.status != 200:
                    raise TransientAPIError(f"GitHub returned HTTP {response.status}")
                raw = response.read()
        except urllib.error.HTTPError as error:
            if error.code in {401, 403, 404, 422}:
                raise GateError(f"GitHub API rejected trusted gate request with HTTP {error.code}") from error
            raise TransientAPIError(f"GitHub API returned HTTP {error.code}") from error
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            raise TransientAPIError(f"GitHub API transport error: {error}") from error
        try:
            value = json.loads(raw)
        except (TypeError, ValueError) as error:
            raise TransientAPIError("GitHub API returned non-JSON data") from error
        if not isinstance(value, dict):
            raise GateError("GitHub API returned an unexpected JSON type")
        return value


def collect_snapshot(client, expected, source_sha):
    repository = client.get("")
    canonical_ref = client.get("/git/ref/heads/main")
    workflow_snapshots = []
    for workflow in expected["workflows"]:
        workflow_file = client.get(
            f"/contents/{workflow['path']}",
            {"ref": source_sha},
        )
        runs = client.get(
            f"/actions/workflows/{workflow['id']}/runs",
            {"branch": "main", "event": "push", "head_sha": source_sha, "per_page": 100},
        )
        workflow_snapshot = {
            "workflow_id": workflow["id"],
            "workflow_file": workflow_file,
            "runs": runs,
        }
        run_list = runs.get("workflow_runs") if isinstance(runs, dict) else None
        if isinstance(run_list, list) and len(run_list) == 1 and isinstance(run_list[0], dict):
            run = run_list[0]
            suite_url = run.get("check_suite_url")
            run_id = run.get("id")
            attempt = run.get("run_attempt")
            if isinstance(suite_url, str):
                workflow_snapshot["check_suite"] = client.get(suite_url)
            if _positive_int(run_id) and _positive_int(attempt):
                workflow_snapshot["jobs"] = client.get(
                    f"/actions/runs/{run_id}/attempts/{attempt}/jobs",
                    {"per_page": 100},
                )
        workflow_snapshots.append(workflow_snapshot)
    return {
        "repository": repository,
        "canonical_ref": canonical_ref,
        "workflows": workflow_snapshots,
    }


def canonical_once(client, expected_config, source_sha):
    expected = validate_expected(expected_config, source_sha)
    try:
        _validate_repository(client.get(""), expected)
        _validate_ref(client.get("/git/ref/heads/main"), expected)
    except (GateError, TransientAPIError) as error:
        print(f"FAIL {error}")
        return 1
    print(f"OK canonical main is {source_sha}")
    return 0


def gate(client, expected_config, source_sha, deadline_seconds, poll_seconds):
    expected = validate_expected(expected_config, source_sha)
    deadline = time.monotonic() + deadline_seconds
    while True:
        try:
            snapshot = collect_snapshot(client, expected, source_sha)
            rc, message = evaluate(snapshot, expected, source_sha)
        except TransientAPIError as error:
            rc, message = 2, f"WAIT {error}"
        except GateError as error:
            rc, message = 1, f"FAIL {error}"
        print(message, flush=True)
        if rc != 2:
            return rc
        if time.monotonic() >= deadline:
            print("FAIL trusted CI verdict was not complete before the bounded deadline", flush=True)
            return 1
        time.sleep(poll_seconds)


def _decode_expected(encoded):
    _require(isinstance(encoded, str) and encoded, "EXPECTED_WORKFLOWS_B64 is required")
    try:
        return json.loads(base64.b64decode(encoded, validate=True))
    except (ValueError, TypeError, json.JSONDecodeError) as error:
        raise GateError("trusted workflow configuration is not valid base64 JSON") from error


def trusted_environment_main(mode):
    try:
        _require(mode in {"gate", "canonical"}, "TRUSTED_GATE_MODE must be gate or canonical")
        expected = _decode_expected(os.environ.get("EXPECTED_WORKFLOWS_B64", ""))
        source_sha = os.environ.get("SOURCE_SHA", "")
        validated = validate_expected(expected, source_sha)
        token = os.environ.get("GH_TOKEN", "")
        _require(token, "GH_TOKEN is required")
        client = GitHubClient(validated["repository"], token)
        if mode == "canonical":
            return canonical_once(client, validated, source_sha)
        deadline = int(os.environ.get("GATE_DEADLINE_SECONDS", "1500"))
        poll = int(os.environ.get("GATE_POLL_SECONDS", "20"))
        _require(0 < deadline <= 3600, "gate deadline is outside the trusted bound")
        _require(1 <= poll <= 60, "gate poll interval is outside the trusted bound")
        return gate(client, validated, source_sha, deadline, poll)
    except (GateError, ValueError) as error:
        print(f"FAIL {error}")
        return 1


def fixture_main():
    try:
        document = json.load(sys.stdin)
        _require(isinstance(document, dict), "fixture must be an object")
        rc, message = evaluate(document.get("snapshot"), document.get("expected"), document.get("source_sha"))
    except (GateError, ValueError, TypeError) as error:
        rc, message = 1, f"FAIL {error}"
    print(message)
    return rc


def main():
    trusted_mode = os.environ.get("TRUSTED_GATE_MODE")
    if trusted_mode:
        rc = trusted_environment_main(trusted_mode)
        result_file = os.environ.get("GATE_RESULT_FILE")
        if result_file:
            with open(result_file, "w", encoding="ascii") as handle:
                handle.write(f"{rc}\n")
            return 0
        return rc
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("fixture",), nargs="?", default="fixture")
    parser.parse_args()
    return fixture_main()


if __name__ == "__main__":
    sys.exit(main())
