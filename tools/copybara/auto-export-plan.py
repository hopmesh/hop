#!/usr/bin/env python3
"""Push-path preflight + changed-component detection for auto-export.

The dispatch path is gated by the human `authorize` job. The push path (merge to protected main,
export only) is gated HERE: it re-validates that this really is a push to the current canonical
protected main, then computes which components changed so only those mirrors are published. "Changed"
means any path in that component's copy.bara.sky origin_files moved, which is its subtree AND the
shared files spliced into its export, not the subtree alone.

Env in (workflow):
  REPOSITORY, EVENT_REPOSITORY, EVENT_NAME, REF, DEFAULT_BRANCH, REF_PROTECTED, SHA, BEFORE, GH_TOKEN
Outputs (GITHUB_OUTPUT): components (space list), repos (comma list), any (true|false)
"""

import json
import os
import re
import sys
import textwrap
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


def _fragment(config_text, pattern, label):
    match = re.search(pattern, config_text, re.S | re.M)
    if match is None:
        raise SystemExit(f"auto-export: copy.bara.sky fragment is missing: {label}")
    return textwrap.dedent(match.group(0))


def origin_paths(config_text, components):
    """Per-component origin_files paths, DERIVED from copy.bara.sky rather than restated here.

    The trigger set and the export set have to be the same set. A component's export carries its own
    subtree PLUS the shared files copy.bara.sky splices in (the release provenance verifier, the
    release artifact helper, the component map, the export-smoke contract, and for some components the
    native signing public key, the crates publish helper, sdk/hop.h, or the vendored Elixir sources).
    Detecting changes by subtree prefix alone left every one of those un-triggerable: rotating the
    native signing key exported nothing, and the mirrors kept verifying against the superseded key.

    Starlark is a Python dialect and the fragments below are literal Python, so they are executed as
    written. Re-implementing them in this file is exactly the drift this function exists to remove.
    """
    namespace = {}
    for line in re.findall(r'^[A-Z][A-Z0-9_]* = "[^"]*"$', config_text, re.M):
        exec(line, {}, namespace)
    for label in ("RUST_MIRRORS", "NATIVE_COMPONENTS"):
        exec(_fragment(config_text, rf"^{label} = \[.*?\]$", label), {}, namespace)
    flags = _fragment(config_text, r"^    is_rust = .*?^    carries_header = .*?$", "component flags")
    block = _fragment(
        config_text,
        r"^    origin_paths = \[.*?(?=^    export_excludes = )",
        "origin_paths block",
    )
    out = {}
    for name, entry in components.items():
        scope = dict(namespace, name=name, prefix=entry["prefix"])
        exec(flags, {}, scope)
        exec(block, {}, scope)
        out[name] = list(scope["origin_paths"])
    return out


def path_matches(pattern, path):
    """Match one origin_files pattern against one changed path, conservatively.

    Only the two shapes copy.bara.sky actually uses are handled: a bare file path and a `<dir>/**`
    subtree. Anything else raises rather than silently matching nothing, so a new glob shape cannot
    become an un-triggerable export input.
    """
    if pattern.endswith("/**"):
        base = pattern[: -len("/**")]
        return path == base or path.startswith(base + "/")
    if "*" in pattern or "?" in pattern:
        raise SystemExit(f"auto-export: unsupported origin_files pattern: {pattern}")
    return path == pattern


def changed_components(files, components, paths_by_component):
    """Which components must export, given the changed paths and each component's origin_files."""
    out = []
    for name in components:
        patterns = paths_by_component.get(name)
        if patterns is None:
            raise SystemExit(f"auto-export: component has no origin_files: {name}")
        if any(path_matches(pattern, f) for pattern in patterns for f in files):
            out.append(name)
    return out


def check_trigger_coverage(components, declared, trigger=None):
    """Assert the trigger set is a superset of the export set.

    `declared` is each component's copy.bara.sky origin_files (what travels out on export). `trigger`
    is what auto-export actually fires on, and defaults to `declared` because they are now the same
    derivation. Passing them separately is what lets the self-test prove the old subtree-prefix rule
    fails this check: a path that travels out but cannot fire its own export is the defect.
    """
    trigger = declared if trigger is None else trigger
    for name, patterns in sorted(declared.items()):
        if not patterns:
            raise SystemExit(f"auto-export: component declares no origin_files: {name}")
        for pattern in patterns:
            probe = pattern[: -len("/**")] + "/probe" if pattern.endswith("/**") else pattern
            if name not in changed_components([probe], components, trigger):
                raise SystemExit(
                    f"auto-export: {name} would NOT export for its own origin path {pattern} "
                    f"(probe {probe}); the trigger set is narrower than the export set"
                )
    return True


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
    paths_by_component = origin_paths((here / "copy.bara.sky").read_text(), components)
    check_trigger_coverage(components, paths_by_component)
    preflight(env)
    files = _changed_files(env)
    changed = changed_components(files, components, paths_by_component)
    out = env.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a", encoding="utf-8") as handle:
            handle.write("components=" + " ".join(changed) + "\n")
            handle.write("repos=" + ",".join(changed) + "\n")
            handle.write("any=" + ("true" if changed else "false") + "\n")
    print("auto-export: changed components =", changed or "(none)", file=sys.stderr)


if __name__ == "__main__":
    main()
