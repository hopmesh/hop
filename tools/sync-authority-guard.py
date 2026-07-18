#!/usr/bin/env python3
"""Enforce the component sync workflow's fixed authority boundary."""

import json
import re
from pathlib import Path


COPYBARA_IMAGE = (
    "olivr/copybara:20230129@"
    "sha256:87e2e9089344e64693faebb2ee0ed33b8797358c0420b0fa98325ca611e98679"
)
TOKEN_ACTION = (
    "actions/create-github-app-token@"
    "fee1f7d63c2ff003460e3d139729b119787bc349"
)


class SyncAuthorityError(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise SyncAuthorityError(message)


def job(text, name):
    match = re.search(
        rf"(?ms)^  {re.escape(name)}:\n(.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)", text
    )
    require(match is not None, f"sync job is absent: {name}")
    return match.group(1)


def component_options(text):
    match = re.search(
        r"(?ms)^      component:\n.*?^        options:\n(.*?)(?=^      direction:)", text
    )
    require(match is not None, "component choice list is absent")
    return re.findall(r"^          - ([A-Za-z0-9_.-]+)$", match.group(1), re.MULTILINE)


def check_text(text, components):
    require(component_options(text) == list(components), "workflow component choices drifted")
    authorize = job(text, "authorize")
    select = job(text, "select")
    export = job(text, "export")
    import_job = job(text, "import")

    for literal in (
        'expected = "hopmesh/monorepo"',
        'os.environ["EVENT_NAME"] == "workflow_dispatch"',
        'os.environ["REF"] == "refs/heads/main"',
        'os.environ["DEFAULT_BRANCH"] == "main"',
        'os.environ["REF_PROTECTED"] == "true"',
        'os.environ["ACTOR"] == os.environ["TRIGGERING_ACTOR"]',
        'os.environ["ACTOR"] == os.environ["EVENT_SENDER"]',
        'not os.environ["ACTOR"].endswith("[bot]")',
        "https://api.github.com/repos/hopmesh/monorepo/git/ref/heads/main",
        'current != os.environ["SHA"]',
    ):
        require(literal in authorize, f"canonical preflight check is absent: {literal}")
    require("secrets." not in authorize, "authorize job references a secret")

    require("needs: authorize" in select, "mapping does not depend on authority preflight")
    require("python3 tools/copybara/dispatch.py" in select, "fixed dispatch mapper is absent")
    require("secrets." not in select, "mapping job references a secret")
    require(
        "ref: ${{ needs.authorize.outputs.source_sha }}" in select,
        "mapping checkout is not bound to canonical main SHA",
    )

    for name, block in (("export", export), ("import", import_job)):
        require(
            "needs: [authorize, select]" in block,
            f"{name} does not depend on preflight and fixed mapping",
        )
        require(
            re.search(r"(?m)^    environment:\n      name: component-sync$", block),
            f"{name} does not use the protected component-sync environment",
        )
        require(
            "ref: ${{ needs.authorize.outputs.source_sha }}" in block,
            f"{name} checkout is not bound to canonical main SHA",
        )
        require(block.count(TOKEN_ACTION) == 1, f"{name} App token action drifted")
        require(
            "repositories: ${{ needs.select.outputs.repository }}" in block,
            f"{name} App token is not scoped to the mapped component repository",
        )
        require("owner: hopmesh" in block, f"{name} App token owner drifted")
        require(block.count(COPYBARA_IMAGE) == 1, f"{name} Copybara image is not immutable")
        require("${{ inputs." not in block, f"{name} consumes raw dispatch data")

    require("permission-contents: write" in export, "export token lacks exact destination write scope")
    require("permission-pull-requests: write" not in export, "export token can write pull requests")
    require("permission-contents: read" in import_job, "import token lacks exact source read scope")
    require(
        "permission-pull-requests: read" in import_job,
        "import token lacks exact source PR read scope",
    )
    require("permission-contents: write" not in import_job, "import App token can write mirror contents")
    require(text.count(COPYBARA_IMAGE) == 2, "Copybara image count drifted")
    require("github.com/hopmesh/hop" not in text, "legacy canonical repository remains")


def check_sync_back_text(text, component):
    require("pull_request_target:" in text, f"sync-back trigger drifted: {component}")
    require("actions/checkout@" not in text, f"sync-back executes mirror code: {component}")
    require(
        text.count("      name: component-sync") == 1,
        f"sync-back protected environment drifted: {component}",
    )
    require(text.count(TOKEN_ACTION) == 1, f"sync-back App token action drifted: {component}")
    require("repositories: monorepo" in text, f"sync-back token is not scoped to canonical monorepo: {component}")
    require("permission-actions: write" in text, f"sync-back token cannot dispatch: {component}")
    require("permission-contents: write" not in text, f"sync-back token can write contents: {component}")
    require("--repo hopmesh/monorepo" in text, f"sync-back dispatch repository drifted: {component}")
    require(
        f"-f component={component}" in text,
        f"sync-back component identity drifted: {component}",
    )
    require("-f direction=import" in text, f"sync-back direction drifted: {component}")


def check(root):
    root = Path(root)
    workflow = (root / ".github/workflows/sync-components.yml").read_text(encoding="utf-8")
    components = json.loads(
        (root / "tools/copybara/components.json").read_text(encoding="utf-8")
    )
    check_text(workflow, components)
    for component, entry in components.items():
        sync_back = root / entry["prefix"] / ".github/workflows/sync-back.yml"
        check_sync_back_text(sync_back.read_text(encoding="utf-8"), component)
    print(
        f"sync authority verified: components={len(components)} "
        f"sync_backs={len(components)} image_digests=2"
    )


if __name__ == "__main__":
    try:
        check(Path(__file__).resolve().parent.parent)
    except (SyncAuthorityError, OSError, ValueError, json.JSONDecodeError) as error:
        raise SystemExit(f"sync authority rejected: {error}") from error
