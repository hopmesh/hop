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
    # library.json is PlatformIO (hop-embedded). plan.py resolves a version from it, so this parser
    # must agree: when it did not, the first untagged library.json version (sdk/embedded 0.0.3) made
    # the mirror read return None, which raises and aborts tagging for EVERY component.
    ("library.json", '{"name":"Hop","version":"1.2.3"}', "1.2.3"),
    ("build.gradle.kts", 'group = "sh.hop"\nversion = "1.2.3"\n', "1.2.3"),
    ("pyproject.toml", '[project]\nname = "x"\nversion = "1.2.3"\n', "1.2.3"),
    ("Cargo.toml", '[package]\nname = "x"\nversion = "1.2.3"\n', "1.2.3"),
    ("shard.yml", "name: x\nversion: 1.2.3\n", "1.2.3"),
    ("mix.exs", 'defp project do\n[version: "1.2.3"]\nend\n', "1.2.3"),
    ("pubspec.yaml", "name: x\nversion: 1.2.3\n", "1.2.3"),
    ("hop-endpoint.gemspec", 'Gem::Specification.new do |s|\n  s.version = "1.2.3"\nend\n', "1.2.3"),
    ("version.rb", 'module Hop\n  VERSION = "1.2.3"\nend\n', "1.2.3"),
]
for filename, text, want in cases:
    got = tag_mod.version_from_text(filename, text)
    assert got == want, f"{filename}: parsed {got!r}, wanted {want!r}"

# STRUCTURAL: every manifest plan.py can name as a `source` must be parseable by the tagger. The two
# resolvers are a matched pair (plan picks the version, the tagger re-reads it off the mirror to
# confirm the export landed), and a manifest known to only one of them is not a cosmetic mismatch: an
# unparseable source raises and aborts the WHOLE tagging run, so ONE unknown manifest blocks EVERY
# component's release. That is how library.json (hop-embedded) and build.gradle.kts (hop-sdk-android)
# both sat unhandled here, latent until each got a version the mirror had not tagged yet. Enumerated
# from plan.py's own source strings so a newly supported ecosystem cannot be added to one side alone.
plan_source_text = (root / "tools/release/plan.py").read_text(encoding="utf-8")
plan_sources = set(re.findall(r'return version, "([^"]+)"', plan_source_text))
assert plan_sources, "no plan.py manifest sources found; this structural check stopped testing anything"
# A fixture per ecosystem, all declaring the SAME version, so a parser that returns something other
# than 1.2.3 (or nothing) is a failure. Gemspecs are matched by suffix, so plan.py names them
# dynamically ("*.gemspec"); the table above already covers that parser by its real filename.
fixtures = {filename: text for filename, text, _ in cases}
unfixtured = sorted(s for s in plan_sources if s not in fixtures and not s.endswith(".gemspec"))
assert not unfixtured, f"no parser fixture for plan.py sources {unfixtured}; add one to `cases` above"
missing = sorted(
    source
    for source in plan_sources
    if not source.endswith(".gemspec")
    and tag_mod.version_from_text(source, fixtures[source]) != "1.2.3"
)
assert not missing, (
    f"plan.py resolves versions from {missing} but tag-mirrors.version_from_text cannot; "
    "an unparseable source aborts tagging for every component"
)

# An inherited Cargo version with NO workspace root in the same file is genuinely unverifiable.
assert tag_mod.version_from_text("Cargo.toml", '[package]\nversion.workspace = true\n') is None

# But that is NOT the manifest the mirror receives, and asserting it against an inline literal is how
# this parser came to permanently defer every Rust mirror. The real export injects copy.bara.sky's
# [workspace.package] preamble ahead of [package], so the inherited version IS resolvable there. The
# fixture below is the ACTUAL export transformation, not a hypothetical manifest: a preamble change
# that breaks version resolution reddens here.
smoke = load("package_export_smoke", "tools/package-export-smoke.py")
by_component = {entry["component"]: entry for entry in entries}
rust_export_versions = {}
for component in sorted(smoke.RUST_MIRRORS):
    if component not in by_component:
        continue
    manifest = smoke.expected_export_tree(root, component)["Cargo.toml"][1].decode("utf-8")
    got = tag_mod.version_from_text("Cargo.toml", manifest)
    planned = by_component[component]["version"]
    assert got is not None, f"{component}: the real exported Cargo.toml reads as unverifiable"
    assert got == planned, f"{component}: exported manifest declares {got!r}, plan wants {planned!r}"
    rust_export_versions[component] = got
# No Rust crate mirror survives the 2026-08 retirement (COMPONENTS carries no Cargo-managed prefix:
# sdk/go, sdk/crystal, sdk/apple, bearers/apple), so the loop above is empty BY CONSTRUCTION and this
# used to hard-assert on hop-core. The
# check is kept as a conditional rather than deleted: its point is that the injected
# [workspace.package] preamble still resolves an inherited version in a REAL export, and if a Rust
# crate is ever mirrored again that guard comes back on its own instead of staying silently off.
if smoke.RUST_MIRRORS:
    assert rust_export_versions, "Rust mirrors are registered but none resolved an exported version"

# Every releasable component must be able to REACH a tagging decision once its mirror is synced. A
# component that can never be tagged is a release path that silently does nothing forever, which is
# exactly what the inherited-version parse did to the four crates.io mirrors.
for entry in entries:
    if entry["source"] == tag_mod.ANCHOR_SOURCE:
        synced = None
    elif entry["component"] in rust_export_versions:
        synced = rust_export_versions[entry["component"]]
    else:
        synced = entry["version"]
    tagged, reason = tag_mod.decide(entry, False, synced)
    assert tagged, f"{entry['component']}: a synced mirror still cannot be tagged ({reason})"

# --- the tag/skip policy ------------------------------------------------------------------------
manifest = {"component": "hop-sdk-crystal", "version": "1.2.3", "source": "shard.yml"}
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

# --- the source must be RELEASABLE before a tag is created ----------------------------------------
# Tagging starts a publish, and the mirror's release job refuses a source commit whose CI gate or
# native-artifacts run is not green. The export finishes in seconds and those take ~20 minutes, so
# tagging on export completion produced tags that could not publish, and since tags are never moved
# each one stranded that version. These pin the readiness check so that race cannot come back.
_calls = {}


def _fake_source(responses):
    def _request(path, token, method="GET", payload=None):
        _calls[path] = _calls.get(path, 0) + 1
        for fragment, value in responses.items():
            if fragment in path:
                return value
        return None, 404
    return _request


def _checks(status, conclusion):
    return ({"check_runs": [{"name": "CI gate", "status": status,
                             "conclusion": conclusion, "started_at": "2026-01-01T00:00:00Z"}]}, 200)


def _native(runs):
    return ({"workflow_runs": [dict(r, head_sha="a" * 40) for r in runs]}, 200)


_original_request = tag_mod.request
try:
    green = {"check-runs": _checks("completed", "success"),
             "native-artifacts.yml/runs": _native([{"status": "completed", "conclusion": "success"}])}
    tag_mod.request = _fake_source(green)
    ok, why = tag_mod.source_is_releasable("a" * 40, "t")
    assert ok, f"a fully green source was refused: {why}"

    # CI gate still running, or failed, is not releasable.
    for state, conclusion in (("in_progress", None), ("completed", "failure")):
        tag_mod.request = _fake_source({**green, "check-runs": _checks(state, conclusion)})
        ok, why = tag_mod.source_is_releasable("a" * 40, "t")
        assert not ok, f"released from a source whose CI gate was {state}/{conclusion}"

    # Native artifacts unfinished, failed, or absent is not releasable. This is the exact state that
    # produced "canonical native artifact run is not successful" on every component.
    for runs, label in (
        ([{"status": "in_progress", "conclusion": None}], "still building"),
        ([{"status": "completed", "conclusion": "failure"}], "failed"),
        ([], "never started"),
    ):
        tag_mod.request = _fake_source({**green, "native-artifacts.yml/runs": _native(runs)})
        ok, why = tag_mod.source_is_releasable("a" * 40, "t")
        assert not ok, f"released from a source whose native artifacts were {label}"

    # An unreadable canonical repo must fail CLOSED, never be treated as ready.
    tag_mod.request = lambda *a, **k: (None, 403)
    ok, why = tag_mod.source_is_releasable("a" * 40, "t")
    assert not ok, "treated an unreadable canonical repo as releasable"
finally:
    tag_mod.request = _original_request

# The GitOrigin-RevId trailer is how a mirror commit names its source; ambiguity must not resolve.
assert tag_mod.GIT_ORIGIN_REV.findall("x\n\nGitOrigin-RevId: " + "b" * 40 + "\n") == ["b" * 40]
assert tag_mod.GIT_ORIGIN_REV.findall("no trailer here") == []

# --- one missing mirror must not block every other component ---------------------------------------
# create-github-app-token mints ONE installation token for the whole repository list, so a single name
# that does not resolve fails the request with 422 "at least one repository that does not exist or is
# not accessible" and NOTHING gets tagged. That is exactly what happened when sdk/flutter gained a
# release.yml before its mirror was created: seventeen components, all unreleasable, because one
# mirror was missing. (That fleet was retired in 2026-08; the names below are three of the live
# mirrors, a fixed sample against a stubbed mirror_exists, not the registry itself.)
# So the plan asks first and drops what cannot be tagged.
_probe = {"hop-sdk-go": True, "hop-sdk-crystal": False, "hop-sdk-apple": None}
_original_exists = plan_mod.mirror_exists
try:
    plan_mod.mirror_exists = lambda component, token: _probe.get(component, True)
    sample = [
        {"component": "hop-sdk-go", "prefix": "sdk/go", "version": "1.2.3", "source": "go.mod"},
        {"component": "hop-sdk-crystal", "prefix": "sdk/crystal", "version": "1.2.3", "source": "shard.yml"},
        {"component": "hop-sdk-apple", "prefix": "sdk/apple", "version": "1.2.3", "source": "Package.swift"},
    ]
    present, missing = plan_mod.partition_by_mirror(sample, "t")
    present_names = [e["component"] for e in present]
    missing_names = [e["component"] for e in missing]
    assert missing_names == ["hop-sdk-crystal"], f"wrong component dropped: {missing_names}"
    assert "hop-sdk-go" in present_names, "a component with a real mirror was dropped"
    # An UNKNOWN answer (403, rate limit, network) must stay in the request. Dropping it would
    # silently skip a releasable component, which is worse than failing the token step.
    assert "hop-sdk-apple" in present_names, "an unverifiable mirror was dropped instead of kept"
finally:
    plan_mod.mirror_exists = _original_exists

# Dropping a component keeps the OTHERS releasable, but it is not an acceptable resting state: that
# component can never publish. The tagger must therefore fail after tagging what it can, never exit 0.
tagger_src = (root / "tools/release/tag-mirrors.py").read_text()
assert 'os.environ.get("MISSING")' in tagger_src, "the tagger does not read the missing-mirror list"
assert tagger_src.index('os.environ.get("MISSING")') > tagger_src.index("release tags created"), (
    "the missing-mirror check runs BEFORE tagging, so one missing mirror still blocks the rest"
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
    # The readiness check needs a token that can read the CANONICAL repo; the mirror App token cannot.
    "SOURCE_TOKEN: ${{ github.token }}",
    # The plan step needs a token to ask whether each mirror exists, and the tagger needs the answer.
    "MISSING: ${{ steps.plan.outputs.missing }}",
    # And Native artifacts completing must re-trigger the tagger, or a deferred component waits forever.
    '"Native artifacts"',
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
