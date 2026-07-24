#!/usr/bin/env bash
# Self-test for the release planner + mirror tagger. Tagging a mirror PUBLISHES that component to a
# public registry and cannot be undone, so the decision policy is pinned here: the tagger must refuse
# to tag anything it has not positively confirmed.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
python3 - "$root" <<'PY'
import importlib.util
import re
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])


def load(name, relative):
    spec = importlib.util.spec_from_file_location(name, root / relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


plan_mod = load("release_plan", "tools/release/plan.py")
tag_mod = load("tag_mirrors", "tools/release/tag-mirrors.py")

# --- the plan resolves every publishing component against the real tree -------------------------
entries = plan_mod.plan(root)
components = json.loads((root / "tools/copybara/components.json").read_text())
expected = sorted(
    name
    for name, entry in components.items()
    if (root / entry["prefix"] / ".github/workflows/release.yml").is_file()
)
assert [e["component"] for e in entries] == expected, "plan drifted from the releasable components"
assert entries, "no releasable components"
for entry in entries:
    assert plan_mod.SEMVER.match(entry["version"]), f"{entry['component']}: bad version"
    assert entry["component"] in components, f"{entry['component']}: not a mirrored component"

# A component the mirror list does not carry must never appear, and a non-semver version must fail.
assert plan_mod.SEMVER.match("0.0.1")
assert not plan_mod.SEMVER.match("v0.0.1")
assert not plan_mod.SEMVER.match("0.1")
assert not plan_mod.SEMVER.match("1.0.0-rc1")

# --- manifest parsing, per ecosystem ------------------------------------------------------------
cases = [
    ("package.json", '{"name":"x","version":"1.2.3"}', "1.2.3"),
    ("pyproject.toml", '[project]\nname = "x"\nversion = "1.2.3"\n', "1.2.3"),
    ("Cargo.toml", '[package]\nname = "x"\nversion = "1.2.3"\n', "1.2.3"),
    ("shard.yml", "name: x\nversion: 1.2.3\n", "1.2.3"),
    ("mix.exs", 'defp project do\n[version: "1.2.3"]\nend\n', "1.2.3"),
    ("hop-endpoint.gemspec", 'Gem::Specification.new do |s|\n  s.version = "1.2.3"\nend\n', "1.2.3"),
    ("version.rb", 'module Hop\n  VERSION = "1.2.3"\nend\n', "1.2.3"),
]
for filename, text, want in cases:
    got = tag_mod.version_from_text(filename, text)
    assert got == want, f"{filename}: parsed {got!r}, wanted {want!r}"

# An inherited Cargo version cannot be resolved from a mirror (no workspace root there), so it must
# read as unverifiable rather than silently passing.
assert tag_mod.version_from_text("Cargo.toml", '[package]\nversion.workspace = true\n') is None

# --- the tag/skip policy ------------------------------------------------------------------------
manifest = {"component": "hop-sdk-node", "version": "1.2.3", "source": "package.json"}
anchor = {"component": "hop-sdk-go", "version": "1.2.3", "source": tag_mod.ANCHOR_SOURCE}


def should(entry, tag_exists, mirror_version, has_tags=True, allow_first=False):
    return tag_mod.decide(entry, tag_exists, mirror_version, has_tags, allow_first)[0]


# Never retag: an existing tag wins over everything, including a matching manifest.
assert not should(manifest, True, "1.2.3"), "retagged an already-tagged version"
assert not should(anchor, True, None), "retagged an already-tagged anchor component"
# Only tag once the mirror actually carries the version.
assert should(manifest, False, "1.2.3"), "refused to tag a mirror already at the version"
assert not should(manifest, False, "1.2.2"), "tagged a mirror still on the old version"
assert not should(manifest, False, None), "tagged a mirror whose manifest could not be read"
# Anchor-versioned components have nothing to compare and no assertion downstream.
assert should(anchor, False, None), "refused to tag an anchor-versioned component"

# A mirror with NO tags at all is a component's FIRST release, not a routine bump, and every untagged
# component qualifies at once. That must never happen automatically; it needs a deliberate dispatch.
assert not should(manifest, False, "1.2.3", has_tags=False), "auto-created a mirror's first ever tag"
assert not should(anchor, False, None, has_tags=False), "auto-created an anchor mirror's first tag"
assert should(manifest, False, "1.2.3", has_tags=False, allow_first=True), "opt-in first tag refused"
assert should(anchor, False, None, has_tags=False, allow_first=True), "opt-in first tag refused"
# The opt-in must not weaken any other rule.
assert not should(manifest, True, "1.2.3", has_tags=False, allow_first=True), "opt-in retagged"
assert not should(manifest, False, "1.2.2", has_tags=False, allow_first=True), "opt-in tagged a stale mirror"
# The tagger reads the opt-in from an env var and treats anything but "yes" as off, so a default
# dispatch (first_tag=no) or a missing value cannot backfill.
tagger_src = (root / "tools/release/tag-mirrors.py").read_text()
assert 'os.environ.get("ALLOW_FIRST_TAG", "").strip().lower() == "yes"' in tagger_src, (
    "the first-tag opt-in is not read strictly from ALLOW_FIRST_TAG"
)

# --- the workflow's authority shape -------------------------------------------------------------
# This workflow mints a write token on PUBLIC repositories and creates tags that publish packages, so
# pin the boundary the same way the sync guard pins its own: it may write contents on exactly the
# planned mirrors and nothing more, and it must not act on a failed export.
workflow = (root / ".github/workflows/release-tags.yml").read_text()
for required in (
    "      name: component-sync",                       # protected environment
    "repositories: ${{ steps.plan.outputs.repos }}",    # scoped to the planned mirrors only
    "owner: hopmesh",
    "permission-contents: write",
    "python3 tools/release/plan.py",                    # the fixed planner decides the scope
    "github.event.workflow_run.conclusion == 'success'",  # never tag after a failed export
):
    assert required in workflow, f"release-tags authority drifted, missing: {required}"
for forbidden in (
    "permission-workflows: write",   # tagging never rewrites mirror workflows
    "permission-administration",
):
    assert forbidden not in workflow, f"release-tags authority widened: {forbidden}"

# The one piece of dispatch data the tagger sees is the first-tag opt-in, and it must arrive as an
# env VALUE compared against a literal in Python, never interpolated into a run: script.
assert "ALLOW_FIRST_TAG: ${{" in workflow, "the first-tag opt-in is not passed as an env value"
run_blocks = re.findall(r"^\s*run: \|?(.*?)(?=^\s{6}- |\Z)", workflow, re.S | re.M)
for block in run_blocks:
    assert "inputs." not in block, "dispatch input is interpolated into a run: script"

# The CI job must actually run this self-test, or the policy above is unenforced.
ci = (root / ".github/workflows/ci.yml").read_text()
assert "bash tools/release/release.test.sh" in ci, "CI does not run the release self-test"
# A new tools/ subdirectory has to be registered in the `full` filter or its own change skips CI.
assert "'tools/release/**'" in ci, "tools/release is not in the full-matrix paths filter"

print("release plan + mirror tagger tests passed")
PY
