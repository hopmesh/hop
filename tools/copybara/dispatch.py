#!/usr/bin/env python3
"""Map workflow dispatch data to fixed Copybara configuration."""

import argparse
import json
import os
import re
from pathlib import Path


HERE = Path(__file__).resolve().parent
COMPONENTS_FILE = HERE / "components.json"


def load_components(path=COMPONENTS_FILE):
    components = json.loads(Path(path).read_text(encoding="utf-8"))
    if not components or len(components) != len(set(components)):
        raise ValueError("component map must contain unique entries")
    return components


def select(component, direction, init_history, pr_number="", components=None):
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

    entry = components[component]
    options = "--ignore-noop --force"
    if init_history == "true":
        options = "--ignore-noop --init-history --force"
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
