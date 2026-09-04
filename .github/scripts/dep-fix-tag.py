#!/usr/bin/env python3
"""Resolve authentic Dependabot PR and post failure notification (INFRA-014).

Verifies that the failing workflow_run originated from the canonical repository
and was triggered by dependabot[bot], resolving the exact matching PR and
binding the notification marker to the failing head SHA.
"""

import json
import os
import subprocess
import sys


def main():
    repo = os.environ.get("REPO", "hopmesh/hop")
    head_repo = os.environ.get("HEAD_REPO", "")
    head_sha = os.environ.get("HEAD_SHA", "")
    head_branch = os.environ.get("BRANCH", "")
    actor = os.environ.get("ACTOR", "")
    run_url = os.environ.get("RUN_URL", "")

    # 1. Require canonical head repository (reject forks)
    if head_repo != "hopmesh/hop":
        print(f"Head repository '{head_repo}' is not canonical hopmesh/hop; skipping.")
        return 0

    # 2. Require authentic dependabot[bot] actor
    if actor != "dependabot[bot]":
        print(f"Actor '{actor}' is not dependabot[bot]; skipping.")
        return 0

    # 3. Require dependabot/ branch prefix
    if not head_branch.startswith("dependabot/"):
        print(f"Branch '{head_branch}' does not start with dependabot/; skipping.")
        return 0

    # 4. Resolve exact PR from GitHub API
    cmd = [
        "gh", "pr", "list",
        "--repo", repo,
        "--head", head_branch,
        "--state", "open",
        "--json", "number,headRefName,headRefOid,author,headRepositoryOwner",
    ]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        print(f"::error::Failed to query open PRs: {res.stderr}")
        return 1

    try:
        prs = json.loads(res.stdout or "[]")
    except json.JSONDecodeError as exc:
        print(f"::error::Failed to parse PR list JSON: {exc}")
        return 1

    matching = [
        pr for pr in prs
        if pr.get("author", {}).get("login") == "dependabot[bot]"
        and pr.get("headRepositoryOwner", {}).get("login") == "hopmesh"
        and (not head_sha or pr.get("headRefOid") == head_sha)
    ]

    if not matching:
        print(f"No authentic Dependabot PR matching head SHA {head_sha} on branch {head_branch}; skipping.")
        return 0

    if len(matching) > 1:
        print(f"::error::Ambiguous PRs matching branch {head_branch}: {[p.get('number') for p in matching]}")
        return 1

    pr = matching[0]
    pr_number = pr["number"]
    pr_head_sha = pr.get("headRefOid", head_sha)

    # Check if already tagged for this exact head SHA
    marker = f"<!-- dep-fix-tag:sha={pr_head_sha} -->"
    legacy_marker = "<!-- dep-fix-tag -->"
    comments_cmd = ["gh", "pr", "view", str(pr_number), "--repo", repo, "--json", "comments"]
    c_res = subprocess.run(comments_cmd, capture_output=True, text=True)
    if c_res.returncode != 0:
        print(f"::error::Failed to query comments for PR #{pr_number}: {c_res.stderr}")
        return 1

    try:
        comments = json.loads(c_res.stdout or "{}").get("comments", [])
    except json.JSONDecodeError as exc:
        print(f"::error::Failed to parse comments JSON: {exc}")
        return 1

    for c in comments:
        body_text = c.get("body", "")
        if marker in body_text or legacy_marker in body_text:
            print(f"PR #{pr_number} already tagged for head SHA {pr_head_sha}; skipping.")
            return 0

    # Post comment
    comment_body = (
        f"{marker}\n\n"
        f"@claude CI is failing on this dependency bump. Do the actual migration this update needs "
        f"(build-config, API, or toolchain changes), keep the bumped version, verify with the full suite, "
        f"and push the fix to this branch. Failed run: {run_url}\n"
        f"If the bump is genuinely incompatible with the codebase, say so on this PR instead of downgrading."
    )
    comment_cmd = ["gh", "pr", "comment", str(pr_number), "--repo", repo, "--body", comment_body]
    c_post = subprocess.run(comment_cmd, capture_output=True, text=True)
    if c_post.returncode != 0:
        print(f"::error::Failed to post comment to PR #{pr_number}: {c_post.stderr}")
        return 1

    print(f"Successfully tagged Claude on PR #{pr_number} for failing head SHA {pr_head_sha}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
