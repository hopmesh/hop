#!/usr/bin/env python3
"""Map workflow dispatch data to fixed Copybara configuration."""

import argparse
import json
import os
import re
import subprocess
from pathlib import Path


HERE = Path(__file__).resolve().parent
COMPONENTS_FILE = HERE / "components.json"
CANONICAL_REMOTE = "https://github.com/hopmesh/hop.git"
FULL_SHA = re.compile(r"[0-9a-f]{40}")


def load_components(path=COMPONENTS_FILE):
    components = json.loads(Path(path).read_text(encoding="utf-8"))
    if not components or len(components) != len(set(components)):
        raise ValueError("component map must contain unique entries")
    return components


def resolves_in_canonical(sha, run=subprocess.run):
    """Is this commit really in the canonical repository?

    A watermark override names the last origin commit already migrated, and Copybara resolves it as
    an ORIGIN reference before it does anything else. A value that does not resolve there fails the
    export at that first step, which is the exact symptom this option exists to clear, so a wrong
    SHA must be rejected here rather than forwarded. The checkout is shallow, so a commit that is
    genuinely present may still be absent locally: ask the remote before deciding it is not real.
    """
    local = run(["git", "cat-file", "-e", f"{sha}^{{commit}}"], capture_output=True)
    if local.returncode == 0:
        return True
    # No credentials involved: the canonical repository is public and this job holds no secret.
    remote = run(
        ["git", "fetch", "--quiet", "--depth=1", CANONICAL_REMOTE, sha],
        capture_output=True,
    )
    return remote.returncode == 0


def select(
    component,
    direction,
    init_history,
    pr_number="",
    components=None,
    last_rev="",
    resolver=resolves_in_canonical,
):
    components = components or load_components()
    if component not in components:
        raise ValueError(f"component is not allowed: {component!r}")
    if direction not in ("export", "import"):
        raise ValueError(f"direction is not allowed: {direction!r}")
    if init_history not in ("true", "false"):
        raise ValueError("init_history must be exactly true or false")
    if init_history == "true" and direction != "export":
        raise ValueError("init_history is allowed only for export")

    # import needs the source mirror PR number: Copybara's github_pr_origin (CHANGE_REQUEST) requires a
    # PR reference. Validate it here (the guard forbids the job from touching raw dispatch inputs, so it
    # is sanitized in the mapper) and emit it as `source_ref`. The olivr container's copybara wrapper
    # appends COPYBARA_SOURCEREF as the LAST arg (after the workflow), which is where the positional PR
    # ref belongs: `<jar> <options> migrate <config> <workflow> <source_ref>`.
    pr_number = pr_number.strip()
    if direction == "import":
        if not re.fullmatch(r"[1-9][0-9]{0,6}", pr_number):
            raise ValueError("import requires pr_number to be a positive integer")
    elif pr_number:
        raise ValueError("pr_number is allowed only for import")

    # last_rev overrides the watermark Copybara would otherwise read from the destination's newest
    # GitOrigin-RevId trailer. It exists because that trailer can name a commit the canonical
    # repository does not have (a mirror fed by a different source stamps its own SHAs), and then
    # every export dies at "Cannot find reference(s)" before it looks at a single file. Overriding it
    # here repairs the state WITHOUT touching the mirror: the export's own commits carry resolvable
    # trailers afterwards, so the next run needs no override.
    #
    # Export only, and never with init_history: seeding a full history and resuming from a point are
    # contradictory instructions, and accepting both would silently honour one of them.
    last_rev = last_rev.strip()
    if last_rev:
        if direction != "export":
            raise ValueError("last_rev is allowed only for export")
        if init_history == "true":
            raise ValueError("last_rev cannot be combined with init_history")
        if not FULL_SHA.fullmatch(last_rev):
            raise ValueError("last_rev must be a full 40-character lowercase commit SHA")
        if resolver is not None and not resolver(last_rev):
            raise ValueError(f"last_rev does not resolve in the canonical repository: {last_rev}")

    entry = components[component]
    options = "--ignore-noop --force"
    if init_history == "true":
        options = "--ignore-noop --init-history --force"
    elif last_rev:
        options = f"--ignore-noop --force --last-rev {last_rev}"
    return {
        "component": component,
        "repository": component,
        "prefix": entry["prefix"],
        "workflow": f"{component}_{direction}",
        "copybara_options": options,
        "source_ref": pr_number if direction == "import" else "",
        "direction": direction,
    }


def write_outputs(values, path):
    with Path(path).open("a", encoding="utf-8") as output:
        for key, value in values.items():
            if "\n" in value or "\r" in value:
                raise ValueError(f"multiline output rejected: {key}")
            output.write(f"{key}={value}\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    components = load_components()
    if args.list:
        print("\n".join(components))
        return

    values = select(
        os.environ.get("SYNC_COMPONENT", ""),
        os.environ.get("SYNC_DIRECTION", ""),
        os.environ.get("SYNC_INIT_HISTORY", ""),
        os.environ.get("SYNC_PR_NUMBER", ""),
        components,
        os.environ.get("SYNC_LAST_REV", ""),
    )
    if args.json:
        print(json.dumps(values, sort_keys=True))
        return
    output = os.environ.get("GITHUB_OUTPUT")
    if not output:
        raise ValueError("GITHUB_OUTPUT is required")
    write_outputs(values, output)


if __name__ == "__main__":
    main()
