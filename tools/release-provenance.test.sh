#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$root" <<'PY'
import importlib.util
import json
import re
import tempfile
from pathlib import Path
import sys

root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("provenance", root / "tools/release-provenance.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def rejected(call, label):
    try:
        call()
    except module.ProvenanceError:
        return
    raise AssertionError(f"expected rejection: {label}")


source = "1" * 40
message = f"publish\n\nGitOrigin-RevId: {source}\n"
assert module.parse_source_revision(message) == source
rejected(lambda: module.parse_source_revision("publish\n"), "absent source metadata")
rejected(
    lambda: module.parse_source_revision(message + f"GitOrigin-RevId: {'2' * 40}\n"),
    "duplicate source metadata",
)
rejected(
    lambda: module.parse_source_revision("GitOrigin-RevId: ../main\n"),
    "malformed source metadata",
)

sha = "a" * 40
event = {
    "created": True,
    "deleted": False,
    "forced": False,
    "before": "0" * 40,
    "after": sha,
    "ref": "refs/tags/v1.2.3",
}
assert module.validate_tag_state("refs/tags/v1.2.3", sha, event, sha, sha, sha, sha) == "v1.2.3"
rejected(
    lambda: module.validate_tag_state(
        "refs/tags/v1.2.3", sha, event, sha, sha, sha, "b" * 40
    ),
    "off-main tag",
)
moved = dict(event, created=False, forced=True, before="c" * 40)
rejected(
    lambda: module.validate_tag_state(
        "refs/tags/v1.2.3", sha, moved, sha, sha, sha, sha
    ),
    "moved tag",
)
rejected(
    lambda: module.validate_tag_state(
        "refs/tags/not-semver", sha, event, sha, sha, sha, sha
    ),
    "invalid tag",
)
replayed = dict(event, after="b" * 40)
rejected(
    lambda: module.validate_tag_state(
        "refs/tags/v1.2.3", sha, replayed, sha, sha, "b" * 40, sha
    ),
    "event after mismatch",
)

run = {
    "id": 42,
    "head_sha": source,
    "head_branch": "main",
    "event": "push",
    "path": ".github/workflows/ci.yml",
    "status": "completed",
    "conclusion": "success",
}
assert module.select_workflow_run([run], source)["id"] == 42
rejected(lambda: module.select_workflow_run([], source), "absent CI run")
rejected(lambda: module.select_workflow_run([run, run], source), "duplicate CI run")

native_run = dict(
    run,
    id=84,
    event="push",
    path=".github/workflows/native-artifacts.yml",
    display_title=f"Native artifacts for {source}",
    head_sha=source,
    run_attempt=3,
)
assert module.select_native_run([native_run], source)["id"] == 84
rejected(lambda: module.select_native_run([], source), "absent native artifact run")
newer_native_run = dict(native_run, id=85, run_attempt=1)
rejected(
    lambda: module.select_native_run([native_run, newer_native_run], source),
    "duplicate native artifact run",
)
rejected(
    lambda: module.select_native_run([dict(native_run, display_title="Native artifacts")], source),
    "native artifact run without source identity",
)
rejected(
    lambda: module.select_native_run([dict(native_run, head_sha="f" * 40)], source),
    "native artifact run with the wrong source SHA",
)
rejected(
    lambda: module.select_native_run([dict(native_run, run_attempt=0)], source),
    "native artifact run without a valid attempt",
)

check = {
    "name": "Rust",
    "details_url": "https://github.com/hopmesh/monorepo/actions/runs/42/job/1",
    "status": "completed",
    "conclusion": "success",
}
module.verify_required_checks(["Rust"], [check], 42)
rejected(lambda: module.verify_required_checks(["Rust"], [], 42), "absent required check")
rejected(
    lambda: module.verify_required_checks(["Rust"], [check, check], 42),
    "duplicate required check",
)
skipped = dict(check, conclusion="skipped")
module.verify_required_checks(["Rust"], [skipped], 42)
gate = dict(check, name="CI gate")
rejected(
    lambda: module.verify_required_checks(["CI gate"], [dict(gate, conclusion="skipped")], 42),
    "skipped aggregate gate",
)
automation = dict(check, name="Automation authority guards")
rejected(
    lambda: module.verify_required_checks(
        ["Automation authority guards"], [dict(automation, conclusion="skipped")], 42
    ),
    "skipped automation guards",
)
rejected(
    lambda: module.verify_required_checks(["Rust"], [check, dict(check, name="Extra")], 42),
    "unexpected workflow check",
)

expected = {"a": ("100644", b"canonical")}
module.compare_trees(expected, dict(expected))
rejected(
    lambda: module.compare_trees(expected, {"a": ("100644", b"forged")}),
    "metadata tree mismatch",
)

with tempfile.TemporaryDirectory() as temp:
    policy = Path(temp) / "variables.tf"
    policy.write_text('variable "github_required_checks" {\n  default = [\n    "Rust",\n    "Web",\n  ]\n}\n')
    assert module.parse_required_checks(policy) == ["Rust", "Web"]
    policy.write_text('variable "github_required_checks" {\n  default = [\n    "Rust",\n    "Rust",\n  ]\n}\n')
    rejected(lambda: module.parse_required_checks(policy), "duplicate policy check")

components = json.loads((root / "tools/copybara/components.json").read_text())
expected_workflows = {
    root / entry["prefix"] / ".github/workflows/release.yml": name
    for name, entry in components.items()
    if (root / entry["prefix"] / ".github/workflows/release.yml").is_file()
}
actual_workflows = {
    path for path in root.glob("**/.github/workflows/release.yml")
    if "node_modules" not in path.relative_to(root).parts
}
assert actual_workflows == set(expected_workflows), "release workflow is outside the component map"

token_action = (
    "actions/create-github-app-token@"
    "bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0"
)
publish_markers = (
    "cargo publish",
    "crates-publish.py publish",
    "npm publish",
    "pypa/gh-action-pypi-publish@",
    "gem push",
    "mix hex.publish",
    "hex.pm/api/packages/",
    "softprops/action-gh-release@",
    "pio pkg publish",
)
native_components = {"hop-sdk-go", "hop-sdk-apple", "hop-sdk-android", "hop-embedded"}
for workflow, component in expected_workflows.items():
    text = workflow.read_text()
    verify = re.compile(r"release-provenance\.py(?:\s|\\\n)+--component\s+" + re.escape(component))
    expected_environments = 2 if component in native_components else 1
    assert text.count("environment: release") == expected_environments, f"release environment drifted: {workflow}"
    assert text.count(token_action) == 1, f"source token action drifted: {workflow}"
    assert len(verify.findall(text)) == 1, f"provenance invocation drifted: {workflow}"
    assert "fetch-depth: 0" in text and "persist-credentials: false" in text
    assert "HOP_SOURCE_APP_ID" in text and "HOP_SOURCE_APP_PRIVATE_KEY" in text
    assert "permission-actions: read" in text
    assert "permission-checks: read" in text
    assert "permission-contents: read" in text
    assert "repositories: monorepo" in text
    assert "repositories: hopmesh/monorepo" not in text
    lines = text.splitlines()
    verify_line = next(index for index, line in enumerate(lines) if "release-provenance.py" in line)
    publish_lines = [
        index
        for index, line in enumerate(lines)
        if not line.lstrip().startswith("#")
        and any(marker in line for marker in publish_markers)
    ]
    assert publish_lines, f"publish step was not recognized: {workflow}"
    assert verify_line < min(publish_lines), f"publish precedes provenance: {workflow}"

copybara = (root / "tools/copybara/copy.bara.sky").read_text()
assert 'core.move(PROVENANCE_HELPER, ".github/release-provenance.py")' in copybara
assert 'core.move(RELEASE_ARTIFACT_HELPER, ".github/release-artifact.py")' in copybara
assert 'core.move(CRATES_PUBLISH_HELPER, ".github/crates-publish.py")' in copybara
assert 'core.move(COMPONENT_MAP, ".github/components.json")' in copybara
assert 'core.move(EXPORT_SMOKE, ".github/package-export-smoke.py")' in copybara
assert 'core.move(NATIVE_HELPER, "native/native-artifacts.py")' in copybara

for workflow, component in expected_workflows.items():
    if component in native_components:
        workflow_text = workflow.read_text()
        assert "--require-native-artifacts" in workflow_text, f"native provenance not required: {workflow}"
        assert "permission-attestations:" not in workflow_text, f"native source token retains attestation access: {workflow}"
        assert workflow_text.count("native_run_attempt") >= 2, f"native run attempt not bound: {workflow}"
        assert workflow_text.count("native-artifacts.py verify-provenance") == 1, f"local provenance verification drifted: {workflow}"
        assert "native-artifacts.provenance.sigstore.json" in workflow_text, f"local provenance bundle absent: {workflow}"
        assert "native_artifact_name" in workflow_text, f"native input producer identity absent: {workflow}"
        assert "release_artifact_name" in workflow_text, f"release producer identity absent: {workflow}"
        assert "release_artifact_attempt" in workflow_text, f"release producer attempt absent: {workflow}"
        assert "--run-attempt '${{ needs.build.outputs.release_artifact_attempt }}'" in workflow_text, f"release verifier is not producer-bound: {workflow}"
        build_section = workflow_text.split("  build:", 1)[1].split("  publish:", 1)[0]
        publish_section = workflow_text.split("uses: softprops/action-gh-release@", 1)[1]
        assert "native-artifacts.provenance.sigstore.json" in build_section, f"authoritative provenance not staged: {workflow}"
        assert (
            "native-artifacts.provenance.sigstore.json" in publish_section
            or "files: ${{ runner.temp }}/release/*" in publish_section
        ), f"authoritative provenance not published: {workflow}"

native_workflow = (root / ".github/workflows/native-artifacts.yml").read_text()
assert "native-release-bundle-${{ github.run_attempt }}" in native_workflow
assert "native-artifacts.py download-partials" in native_workflow
assert "pattern: native-*-${{ needs.authorize.outputs.source_sha }}-${{ github.run_attempt }}" not in native_workflow
assert "github.event.repository.visibility == 'public' || github.event.enterprise != null" in native_workflow
assert "native-artifacts.py verify-provenance" in native_workflow
assert "native-artifacts.py authorize-ci" in native_workflow
assert "native-artifacts.provenance.sigstore.json" in native_workflow
assert "workflow_run" not in native_workflow
assert "continue-on-error" not in native_workflow

embedded_release = (root / "sdk/embedded/.github/workflows/release.yml").read_text()
embedded_publish = embedded_release.split("uses: softprops/action-gh-release@", 1)[1]
assert "release/native/native-artifacts.provenance.sigstore.json" in embedded_publish

ci_workflow = (root / ".github/workflows/ci.yml").read_text()
assert "npm test --prefix tools/native-attestation" in ci_workflow
assert "'tools/native-attestation/**'" in ci_workflow

local_attestation = (root / "tools/native-attestation/create.mjs").read_text()
assert "https://fulcio.githubapp.com" in local_attestation
assert "https://timestamp.githubapp.com" in local_attestation
assert local_attestation.count("timeout: SIGNING_TIMEOUT_MS") == 2
assert local_attestation.count("retry: SIGNING_RETRIES") == 2
assert "writeAttestation" not in local_attestation
lock = json.loads((root / "tools/native-attestation/package-lock.json").read_text())
assert "node_modules/@actions/attest" not in lock["packages"]
expected_sigstore = {
    "node_modules/@sigstore/bundle": (
        "5.0.0",
        "sha512-wefjygudENbzbQMks1t5u34EP0fFoD0XvaEP7DOUP/sXKvogzEJYFw5E6pegGyp3onGWzVEYKVa3bNZWyTYX+A==",
    ),
    "node_modules/@sigstore/core": (
        "4.0.1",
        "sha512-9v5hRjujn5NXq8o7XFEUgLyAtdr5Iisb4pzM05u3K61IS5q3hP3luWAndk0RkPPLTUFoTbg7Vb84UQ1ZQeajWQ==",
    ),
    "node_modules/@sigstore/sign": (
        "5.0.0",
        "sha512-DSFivqz9/i5AkwZ5fq0YdjaJlc4o1WeS2Zffon0kqtChx0vy4W9NOjkEet9bF2vkzOufX72eVH8kZBIGtcBp1w==",
    ),
}
for package, expected in expected_sigstore.items():
    dependency = lock["packages"][package]
    assert (dependency["version"], dependency["integrity"]) == expected

print("release provenance tests passed")
PY
