#!/usr/bin/env python3
"""Fail when a deploy-critical workflow has not GENUINELY run inside its freshness window.

The defect this exists for is not a red run. It is a green one. A job gated on an `if` that evaluates
false is SKIPPED, and a run whose only meaningful job skipped still reports `success`, so a dashboard, a
required-check list, and a human scanning Actions all read it as healthy. Three breakages hid behind that
at once in 2026-08: runtime-deploy dead for nine days, sync-components for four, and bootstrap-apply not
having applied in weeks while every run showed success from a validate-only pass.

So this guard ignores run conclusions entirely and asks a narrower question per entry in
tools/workflow-freshness.json: when did the NAMED JOB last reach a real conclusion, and was that inside
max_age_days? A job that only ever skipped counts as never having run.

FAILS CLOSED. If the API cannot be reached, or returns something unparseable, that is a FAILURE and not a
pass. A freshness check whose network error reads as "fresh" is worse than no check, because it removes
the one signal it was added to provide. Same reasoning as the fetch-then-classify gates elsewhere here.

Usage:
    python3 tools/workflow-freshness-guard.py                    # live, needs GITHUB_TOKEN
    python3 tools/workflow-freshness-guard.py --fixture f.json   # offline, for the self-test
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import pathlib
import sys
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "tools/workflow-freshness.json"
# Falls back to the canonical repository when run outside Actions. hopmesh/hop is the source of truth
# now; hopmesh/monorepo was archived, so the old default would have queried a repo whose Actions are
# frozen and reported every deploy-critical job as stale.
REPO = os.environ.get("GITHUB_REPOSITORY", "hopmesh/hop")
API = "https://api.github.com"
# Enough history to see past a stretch of skipped runs. bootstrap-apply had twelve consecutive
# pull_request runs whose apply job skipped; a shallower window would have called that "never ran"
# for the wrong reason, or missed a real run sitting just behind them.
RUNS_PER_WORKFLOW = 60


class GuardError(RuntimeError):
    """A condition that must fail the guard rather than be reported as a pass."""


def _get(url: str) -> dict:
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if not token:
        raise GuardError(
            "no GITHUB_TOKEN/GH_TOKEN in the environment. Refusing to report freshness without being "
            "able to check it: a silent pass here is the exact failure mode this guard exists to catch."
        )
    request = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "hop-workflow-freshness-guard/1",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        raise GuardError(f"GET {url} failed: HTTP {exc.code} {exc.reason}") from exc
    except Exception as exc:  # noqa: BLE001 - any failure to observe must fail the guard
        raise GuardError(f"GET {url} failed: {exc}") from exc


def load_manifest(path: pathlib.Path = MANIFEST) -> list[dict]:
    data = json.loads(path.read_text(encoding="utf-8"))
    entries = data.get("workflows")
    if not entries:
        raise GuardError(f"{path} declares no workflows; an empty manifest checks nothing")
    for entry in entries:
        for key in ("file", "job", "max_age_days", "why"):
            if key not in entry:
                raise GuardError(f"{path}: entry {entry!r} is missing {key!r}")
    return entries


def last_real_run(entry: dict, fetch=_get) -> tuple[datetime.datetime | None, str | None, int, int]:
    """Return (when the named job last really concluded, its conclusion, runs examined, times it skipped).

    "Really concluded" means the job reached success or failure. skipped, cancelled and a null
    conclusion all mean the job did not execute, which is the whole point: those are the states that
    render as a green run while doing nothing. Deploy-critical automation must reach success.
    """
    runs = fetch(f"{API}/repos/{REPO}/actions/workflows/{entry['file']}/runs?per_page={RUNS_PER_WORKFLOW}")
    if "workflow_runs" not in runs:
        raise GuardError(f"{entry['file']}: response has no workflow_runs key; refusing to guess")
    examined = skipped = 0
    for run in runs["workflow_runs"]:
        examined += 1
        jobs = fetch(f"{API}/repos/{REPO}/actions/runs/{run['id']}/jobs?per_page=100")
        if "jobs" not in jobs:
            raise GuardError(f"run {run['id']}: response has no jobs key; refusing to guess")
        for job in jobs["jobs"]:
            if job.get("name") != entry["job"]:
                continue
            if job.get("conclusion") in ("success", "failure"):
                stamp = job.get("completed_at") or run.get("updated_at")
                return (
                    datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00")),
                    job.get("conclusion"),
                    examined,
                    skipped,
                )
            skipped += 1
    return None, None, examined, skipped


def check(entries: list[dict], now: datetime.datetime, fetch=_get) -> list[str]:
    problems: list[str] = []
    for entry in entries:
        when, conclusion, examined, skipped = last_real_run(entry, fetch=fetch)
        label = f"{entry['file']} :: {entry['job']}"
        if when is None:
            problems.append(
                f"{label}: NEVER really ran in the last {examined} runs ({skipped} skipped). {entry['why']}"
            )
            print(f"  FAIL  {label}: no real execution in {examined} runs, {skipped} skipped")
            continue
        age = (now - when).days
        if conclusion == "failure":
            problems.append(
                f"{label}: last real run FAILED ({age}d ago). Deploy-critical automation must conclude with success. {entry['why']}"
            )
            print(f"  FAIL  {label}: last real run FAILED ({age}d ago, limit {entry['max_age_days']}d)")
            continue
        state = "ok" if age <= entry["max_age_days"] else "FAIL"
        print(f"  {state:<4}  {label}: last real run {age}d ago (limit {entry['max_age_days']}d)")
        if age > entry["max_age_days"]:
            problems.append(
                f"{label}: last real run was {age} days ago, limit is {entry['max_age_days']}. {entry['why']}"
            )
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", help="read API responses from a JSON fixture instead of the network")
    parser.add_argument("--now", help="override the clock, ISO 8601, for deterministic tests")
    args = parser.parse_args()

    fetch = _get
    if args.fixture:
        canned = json.loads(pathlib.Path(args.fixture).read_text(encoding="utf-8"))

        def fetch(url: str) -> dict:  # noqa: ANN001
            for pattern, payload in canned.items():
                if pattern in url:
                    if payload == "__ERROR__":
                        raise GuardError(f"fixture forces a fetch failure for {url}")
                    return payload
            raise GuardError(f"fixture has no entry matching {url}")

    now = (
        datetime.datetime.fromisoformat(args.now)
        if args.now
        else datetime.datetime.now(datetime.timezone.utc)
    )

    try:
        entries = load_manifest()
        print(f"workflow freshness, {len(entries)} deploy-critical job(s), repo {REPO}")
        problems = check(entries, now, fetch=fetch)
    except GuardError as exc:
        print(f"::error::workflow-freshness-guard could not verify freshness: {exc}", file=sys.stderr)
        return 1

    if problems:
        for problem in problems:
            print(f"::error::{problem}", file=sys.stderr)
        print(f"\n{len(problems)} deploy-critical job(s) are not demonstrably running.", file=sys.stderr)
        return 1
    print("all deploy-critical jobs have really run inside their window")
    return 0


if __name__ == "__main__":
    sys.exit(main())
