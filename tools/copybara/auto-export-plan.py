#!/usr/bin/env python3
"""Push-path preflight + changed-component detection for auto-export.

The dispatch path is gated by the human `authorize` job. The push path (merge to protected main,
export only) is gated HERE: it re-validates that this really is a push to the current canonical
protected main, then computes which component subtrees changed so only those mirrors are published.

Env in (workflow):
  REPOSITORY, EVENT_REPOSITORY, EVENT_NAME, REF, DEFAULT_BRANCH, REF_PROTECTED, SHA, BEFORE, GH_TOKEN
Outputs (GITHUB_OUTPUT): components (space list), repos (comma list), any (true|false)
"""

import json
import os
import re
import sys
import urllib.request
from pathlib import Path

API = "https://api.github.com/repos/hopmesh/monorepo/"
EXPECTED = "hopmesh/monorepo"


def _api(path, token):
    req = urllib.request.Request(
        API + path,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": "Bearer " + token,
            "User-Agent": "hop-component-sync",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    with urllib.request.urlopen(req, timeout=30) as response:
        return json.load(response)


def preflight(env):
    """Reject anything that is not a push to the current canonical protected main."""
    checks = {
        "repository": env.get("REPOSITORY") == EXPECTED,
        "event repository": env.get("EVENT_REPOSITORY") == EXPECTED,
        "event": env.get("EVENT_NAME") == "push",
        "ref": env.get("REF") == "refs/heads/main",
        "default branch": env.get("DEFAULT_BRANCH") == "main",
        "protected ref": env.get("REF_PROTECTED") == "true",
        "full SHA": re.fullmatch(r"[0-9a-f]{40}", env.get("SHA", "")) is not None,
    }
    failed = [name for name, ok in checks.items() if not ok]
    if failed:
        raise SystemExit("auto-export authority rejected: " + ", ".join(failed))
    current = _api("git/ref/heads/main", env["GH_TOKEN"]).get("object", {}).get("sha", "")
    if current != env["SHA"]:
        raise SystemExit("auto-export authority rejected: push SHA is not current canonical main")


def changed_components(files, components):
    """Pure mapping: which components own any of the changed paths (prefix match)."""
    out = []
    for name, entry in components.items():
        prefix = entry["prefix"]
        boundary = prefix.rstrip("/") + "/"
        if any(f == prefix or f.startswith(boundary) for f in files):
            out.append(name)
    return out


def _changed_files(env):
    sha = env["SHA"]
    base = env.get("BEFORE", "")
    # A brand-new branch or unknown base has an all-zero BEFORE; fall back to the first parent.
    if not re.fullmatch(r"[0-9a-f]{40}", base) or set(base) == {"0"}:
        parents = _api("commits/" + sha, env["GH_TOKEN"]).get("parents", [])
        base = parents[0]["sha"] if parents else sha
    files, page = [], 1
    while True:
        data = _api(f"compare/{base}...{sha}?per_page=100&page={page}", env["GH_TOKEN"])
        batch = data.get("files", [])
        files += [f["filename"] for f in batch]
        if len(batch) < 100:
            break
        page += 1
    return files


def main():
    env = os.environ
    here = Path(__file__).resolve().parent
    components = json.loads((here / "components.json").read_text())
    preflight(env)
    files = _changed_files(env)
    changed = changed_components(files, components)
    out = env.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a", encoding="utf-8") as handle:
            handle.write("components=" + " ".join(changed) + "\n")
            handle.write("repos=" + ",".join(changed) + "\n")
            handle.write("any=" + ("true" if changed else "false") + "\n")
    print("auto-export: changed components =", changed or "(none)", file=sys.stderr)


if __name__ == "__main__":
    main()
