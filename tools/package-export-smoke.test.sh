#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$root" <<'PY'
import argparse
import copy
import importlib.util
import io
import json
import os
import pathlib
import re
import shutil
import subprocess
import tarfile
import tempfile
import types
import sys
import zipfile

root = pathlib.Path(sys.argv[1])


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


exports = load("package_exports", root / "tools/package-export-smoke.py")
native = load("native_artifacts", root / "tools/native-artifacts.py")


def rejected(call, label):
    try:
        call()
    except (exports.ExportError, native.ArtifactError, OSError, ValueError):
        return
    raise AssertionError(f"expected rejection: {label}")


components = exports.load_components(root)
# The surviving mirror set after the 2026-08 retirement. Asserted by NAME, not by count: a bare
# integer said nothing about WHICH components, so swapping one for another would have passed. These
# three exist because their package manager cannot resolve a library from a subdirectory (SwiftPM
# needs Package.swift at a repo root; shards has no subdirectory resolver at all) or because the
# import path is materially worse without one (Go subdirectory modules force sdk/go/v1.2.3 tags).
assert sorted(components) == ["hop-sdk-apple", "hop-sdk-crystal", "hop-sdk-go"], sorted(components)
exports.check_copybara_contract(root, components)
with tempfile.TemporaryDirectory(prefix="hop-package-export-test-") as temporary:
    temporary = pathlib.Path(temporary)
    output = temporary / "exports"
    output.mkdir()
    for component in components:
        tree = exports.expected_export_tree(root, component, components)
        destination = output / component
        exports.write_export(tree, destination)
        assert "CLAUDE.md" not in tree
        assert (destination / ".github/release-provenance.py").is_file()
        assert (destination / ".github/package-export-smoke.py").is_file()
        if component in exports.RUST_MIRRORS and ".github/workflows/release.yml" in tree:
            assert (destination / "Cargo.lock").is_file()

    go = output / "hop-sdk-go"
    assert not (go / "install-libhop.py").exists()
    assert (go / "hop.h").read_bytes() == (root / "sdk/hop.h").read_bytes()
    assert (go / "go.mod").read_text().startswith("module github.com/hopmesh/hop-sdk-go\n")
    assert (go / "cmd/hop-install/main.go").is_file()
    assert (go / "cmd/hop-install/native-artifacts-public.pem").read_bytes() == (root / "tools/native-artifacts-public.pem").read_bytes()
    go_source = (go / "hop.go").read_text()
    assert "#cgo pkg-config: hop\n" in go_source
    assert "${SRCDIR}/.." not in go_source
    assert "${SRCDIR}/native/lib" not in go_source

    go_checkout = temporary / "go-checkout"
    (go_checkout / ".git/objects").mkdir(parents=True)
    (go_checkout / ".hg/store").mkdir(parents=True)
    (go_checkout / ".svn").mkdir()
    (go_checkout / ".build").mkdir()
    (go_checkout / "target/debug").mkdir(parents=True)
    (go_checkout / "native/lib").mkdir(parents=True)
    (go_checkout / "go.mod").write_text("module example.invalid/checkout\n")
    (go_checkout / "hop.go").write_text("package hop\n")
    for metadata in (
        ".git/config",
        ".git/objects/fixture",
        ".hg/store/fixture",
        ".svn/entries",
        ".build/cache",
        "target/debug/libhop.a",
        "native/lib/libhop.dylib",
    ):
        (go_checkout / metadata).write_text("excluded\n")
    _, checkout_zip, checkout_prefix = exports.build_go_proxy(go_checkout, temporary / "go-work", "v0.0.1")
    with zipfile.ZipFile(checkout_zip) as source:
        checkout_names = set(source.namelist())
    assert checkout_prefix + "go.mod" in checkout_names
    assert checkout_prefix + "hop.go" in checkout_names
    assert not any(
        marker in name
        for name in checkout_names
        for marker in ("/.git/", "/.hg/", "/.svn/", "/.build/", "/target/", "/native/lib/")
    )
    outside_go_file = temporary / "outside.go"
    outside_go_file.write_text("package outside\n")
    (go_checkout / "escape.go").symlink_to(outside_go_file)
    rejected(
        lambda: exports.build_go_proxy(go_checkout, temporary / "go-forbidden-work", "v0.0.1"),
        "Go module symlink",
    )

    # The assertions that ran against the REAL hop-sdk-elixir export are gone with that mirror
    # (2026-08 retirement). The synthetic fixtures below are KEPT deliberately: they pin
    # elixir_declared_cargo_manifests' rejection of traversing, absolute and symlinked Cargo paths,
    # which is a path-safety property of the parser itself and does not need a live export to hold.

    def cargo_path_fixture(name, raw, create_crate=True):
        fixture = temporary / name
        native = fixture / "native"
        crate = native / "vendor/dep"
        if create_crate:
            crate.mkdir(parents=True)
            (crate / "Cargo.toml").write_text('[package]\nname = "dep"\nversion = "0.0.1"\n')
        else:
            native.mkdir(parents=True)
        (native / "Cargo.toml").write_text(
            '[workspace]\nresolver = "2"\nmembers = []\n\n[workspace.dependencies]\n'
            f"dep = {{ path = {json.dumps(raw)} }}\n"
        )
        return fixture

    valid_cargo = cargo_path_fixture("valid-cargo-path", "vendor/dep")
    assert (valid_cargo / "native/vendor/dep/Cargo.toml").resolve() in exports.elixir_declared_cargo_manifests(valid_cargo)

    outside_crate = temporary / "outside-crate"
    outside_crate.mkdir()
    (outside_crate / "Cargo.toml").write_text('[package]\nname = "outside"\nversion = "0.0.1"\n')
    rejected(
        lambda: exports.elixir_declared_cargo_manifests(cargo_path_fixture("parent-cargo-path", "../outside")),
        "Elixir parent path",
    )
    rejected(
        lambda: exports.elixir_declared_cargo_manifests(cargo_path_fixture("absolute-cargo-path", str(outside_crate))),
        "Elixir absolute path",
    )
    rejected(
        lambda: exports.elixir_declared_cargo_manifests(cargo_path_fixture("windows-cargo-path", "C:/outside")),
        "Elixir Windows absolute path",
    )
    for index, raw in enumerate(("./vendor/dep", "vendor//dep", "vendor/../vendor/dep", "vendor\\dep")):
        rejected(
            lambda raw=raw, index=index: exports.elixir_declared_cargo_manifests(
                cargo_path_fixture(f"nonnormal-cargo-path-{index}", raw)
            ),
            f"Elixir non-normalized path {raw}",
        )
    rejected(
        lambda: exports.elixir_declared_cargo_manifests(
            cargo_path_fixture("missing-cargo-path", "vendor/missing", create_crate=False)
        ),
        "Elixir missing vendor crate",
    )
    symlink_cargo = cargo_path_fixture("symlink-cargo-path", "vendor/dep", create_crate=False)
    (symlink_cargo / "native/vendor").mkdir()
    (symlink_cargo / "native/vendor/dep").symlink_to(outside_crate, target_is_directory=True)
    rejected(
        lambda: exports.elixir_declared_cargo_manifests(symlink_cargo),
        "Elixir symlink escape",
    )

    apple = output / "hop-sdk-apple"
    assert os.access(apple / "install-local-xcframework.py", os.X_OK)
    assert os.access(apple / "with-local-framework.sh", os.X_OK)
    apple_manifest = (apple / "Package.swift").read_text()
    # Pin the URL to the ANCHOR version rather than a literal. Hardcoding v0.0.1 here meant a version
    # bump left the published manifest pointing at the previous release's asset and the test still
    # passed, which is half of why the Apple release stayed broken across two wire versions.
    _anchor_version = exports.workspace_version(root)
    assert (
        f"releases/download/v{_anchor_version}/libhop.xcframework.zip" in apple_manifest
    ), f"Apple manifest does not point at the v{_anchor_version} asset"
    assert '.binaryTarget(name: "CHop", path:' not in apple_manifest
    assert (apple / "Package.local.swift").is_file()

    # The hop-sdk-android and hop-embedded export-shape checks lived here and are gone with those
    # mirrors (2026-08 retirement). What they pinned was per-export packaging (AAR layout, the
    # PlatformIO installer, the AGP symbol-stripping consumer), which has no subject once the export
    # does not exist. The native-artifacts workflow assertions below are NOT component-scoped and stay.

    native_workflow = (root / ".github/workflows/native-artifacts.yml").read_text()
    android_setup = native_workflow.split(
        "- name: Install exact NDK and Rust builders", 1
    )[1].split("- name: Invoke the canonical Android native builder", 1)[0]
    assert "rustup target add" in android_setup
    for target in (
        "aarch64-linux-android",
        "armv7-linux-androideabi",
        "i686-linux-android",
        "x86_64-linux-android",
    ):
        assert target in android_setup, f"Android setup omitted Rust target: {target}"

    for target in (
        "xtensa-esp32-espidf",
        "xtensa-esp32s2-espidf",
        "xtensa-esp32s3-espidf",
        "riscv32imc-esp-espidf",
        "riscv32imac-esp-espidf",
    ):
        assert target in native_workflow
    assert native_workflow.count("-Zbuild-std=std,panic_abort") == 1
    assert "workflow_run" not in native_workflow
    assert "run-name: Native artifacts for ${{ github.sha }}" in native_workflow
    assert "native-artifacts.py authorize-ci" in native_workflow
    assert "needs: [authorize, host-linux, apple, android, embedded, authorize-ci]" in native_workflow
    native_schema = json.loads((root / "tools/native-artifacts.schema.json").read_text())
    assert native_schema["properties"]["artifacts"]["minItems"] == len(native.NATIVE_TARGET_FILENAMES)
    assert native_schema["properties"]["artifacts"]["maxItems"] == len(native.NATIVE_TARGET_FILENAMES)

    source_sha = "1" * 40
    ci_run = {
        "id": 42,
        "head_sha": source_sha,
        "head_branch": "main",
        "event": "push",
        "path": native.CI_WORKFLOW,
        "status": "completed",
        "conclusion": "success",
        "run_attempt": 2,
        "repository": {"full_name": native.CANONICAL_GITHUB_REPOSITORY},
        "head_repository": {"full_name": native.CANONICAL_GITHUB_REPOSITORY},
    }
    ci_runs = {"total_count": 1, "workflow_runs": [ci_run]}
    ci_jobs = {
        "total_count": 2,
        "jobs": [
            {
                "name": name,
                "head_sha": source_sha,
                "run_attempt": 2,
                "status": "completed",
                "conclusion": "success",
            }
            for name in sorted(native.CI_AUTHORIZATION_JOBS)
        ],
    }
    assert native.validate_ci_authorization(ci_runs, ci_jobs, source_sha)["id"] == 42
    wrong_ci = copy.deepcopy(ci_runs)
    wrong_ci["workflow_runs"][0]["head_sha"] = "2" * 40
    rejected(lambda: native.validate_ci_authorization(wrong_ci, ci_jobs, source_sha), "wrong CI source")
    duplicate_ci = copy.deepcopy(ci_runs)
    duplicate_ci["workflow_runs"].append(copy.deepcopy(ci_run))
    duplicate_ci["total_count"] = 2
    rejected(lambda: native.validate_ci_authorization(duplicate_ci, ci_jobs, source_sha), "duplicate CI run")
    failed_jobs = copy.deepcopy(ci_jobs)
    failed_jobs["jobs"][0]["conclusion"] = "failure"
    rejected(lambda: native.validate_ci_authorization(ci_runs, failed_jobs, source_sha), "failed CI gate")
    stale_jobs = copy.deepcopy(ci_jobs)
    stale_jobs["jobs"][0]["run_attempt"] = 1
    rejected(lambda: native.validate_ci_authorization(ci_runs, stale_jobs, source_sha), "stale CI gate")
    original_gh_json = native.gh_json
    original_subprocess_run = native.subprocess.run
    watched_ci = []
    responses = iter((ci_runs, ci_runs, ci_jobs))
    try:
        native.gh_json = lambda _path: next(responses)

        def fake_watch(command, **_kwargs):
            watched_ci.extend(command)
            return types.SimpleNamespace(returncode=0, stdout="", stderr="")

        native.subprocess.run = fake_watch
        native.authorize_ci(types.SimpleNamespace(source_sha=source_sha))
    finally:
        native.gh_json = original_gh_json
        native.subprocess.run = original_subprocess_run
    assert watched_ci[:3] == ["gh", "run", "watch"]
    assert "--exit-status" in watched_ci

    partials = []
    artifact_id = 100
    for base in native.PARTIAL_ARTIFACT_TARGETS:
        partials.append({
            "id": artifact_id,
            "name": f"{base}-{source_sha}-1",
            "expired": False,
        })
        artifact_id += 1
    partials.append({
        "id": artifact_id,
        "name": f"native-apple-{source_sha}-2",
        "expired": False,
    })
    partial_listing = {"total_count": len(partials), "artifacts": partials}
    selected_partials = native.select_partial_artifacts(partial_listing, source_sha, 2)
    selected_attempts = {base: attempt for base, attempt, _artifact, _files in selected_partials}
    assert selected_attempts["native-apple"] == 2
    assert all(
        attempt == 1 for base, attempt in selected_attempts.items() if base != "native-apple"
    )
    missing_partial = copy.deepcopy(partial_listing)
    missing_partial["artifacts"] = [
        artifact for artifact in missing_partial["artifacts"]
        if not artifact["name"].startswith("native-embedded-")
    ]
    missing_partial["total_count"] = len(missing_partial["artifacts"])
    rejected(lambda: native.select_partial_artifacts(missing_partial, source_sha, 2), "missing partial producer")
    duplicate_partial = copy.deepcopy(partial_listing)
    duplicate_partial["artifacts"].append(copy.deepcopy(duplicate_partial["artifacts"][-1]))
    duplicate_partial["artifacts"][-1]["id"] += 1
    duplicate_partial["total_count"] += 1
    rejected(lambda: native.select_partial_artifacts(duplicate_partial, source_sha, 2), "duplicate partial attempt")
    future_partial = copy.deepcopy(partial_listing)
    future_partial["artifacts"].append({
        "id": 999,
        "name": f"native-android-{source_sha}-3",
        "expired": False,
    })
    future_partial["total_count"] += 1
    rejected(lambda: native.select_partial_artifacts(future_partial, source_sha, 2), "future partial attempt")
    partial_zip_payloads = {}
    for _base, _attempt, artifact, expected_files in selected_partials:
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w") as archive_zip:
            for filename in expected_files:
                archive_zip.writestr(filename, b"producer artifact")
        partial_zip_payloads[artifact["id"]] = buffer.getvalue()
    partial_run = {
        "id": 77,
        "run_attempt": 2,
        "head_sha": source_sha,
        "head_branch": "main",
        "event": "push",
        "path": native.NATIVE_WORKFLOW,
        "repository": {"full_name": native.CANONICAL_GITHUB_REPOSITORY},
    }
    original_gh_json = native.gh_json
    original_subprocess_run = native.subprocess.run
    try:
        native.gh_json = lambda path: partial_run if path.endswith("/actions/runs/77") else partial_listing

        def fake_partial_download(command, **kwargs):
            artifact_id = int(command[-1].split("/")[-2])
            kwargs["stdout"].write(partial_zip_payloads[artifact_id])
            return types.SimpleNamespace(returncode=0, stderr=b"")

        native.subprocess.run = fake_partial_download
        partial_output = temporary / "producer-bound-partials"
        native.download_partials(types.SimpleNamespace(
            repository=native.CANONICAL_GITHUB_REPOSITORY,
            run_id=77,
            run_attempt=2,
            source_sha=source_sha,
            output=str(partial_output),
        ))
    finally:
        native.gh_json = original_gh_json
        native.subprocess.run = original_subprocess_run
    assert {path.name for path in partial_output.iterdir()} == set(native.NATIVE_TARGET_FILENAMES.values())

    # The ESP targets have no prebuilt core or std, so every ESP build of libhop must pass
    # -Zbuild-std. libhop-esp-release.yml used to be the other place this had to hold; it was deleted
    # (unprovisionable credentials, superseded by this signed path), so native-artifacts.yml is now the
    # only workflow that builds them and the check follows it there rather than being dropped.
    esp_release = (root / ".github/workflows/native-artifacts.yml").read_text()
    assert esp_release.count("-Zbuild-std=std,panic_abort") == 1
    assert "xtensa-esp32-espidf" in esp_release and "riscv32imc-esp-espidf" in esp_release
    esp_builder = (root / "apps/esp32/hop-sensor/build-libhop-esp.sh").read_text()
    assert "cargo +esp build" in esp_builder
    assert esp_builder.count("-Zbuild-std=std,panic_abort") == 1

    fixture = temporary / "fixture"
    fixture.mkdir()
    stage = temporary / "stage"
    (stage / "lib").mkdir(parents=True)
    (stage / "include").mkdir()
    (stage / "lib/libhop.so").write_bytes(b"fixture-libhop")
    # PLAT-004: this fixture used to hard-code a retired ABI level, the same stale literal the Apple
    # validator asserted, so the two drifted together and could never disagree. Derive it from the Rust
    # const so the fixture tracks the real ABI instead of freezing an old one.
    abi = re.search(r"HOP_ABI_VERSION:\s*u32\s*=\s*(\d+)", (root / "core/hop/src/cabi.rs").read_text()).group(1)
    (stage / "include/hop.h").write_bytes(f"#define HOP_ABI_VERSION {abi}\n".encode())
    archives = {}
    for target, filename in native.NATIVE_TARGET_FILENAMES.items():
        archive_path = fixture / filename
        archive_format = "zip" if filename.endswith(".zip") else "tar.gz"
        native.pack_archive(stage, [], archive_path, archive_format)
        archives[target] = archive_path
    archive = archives["x86_64-unknown-linux-gnu"]
    key = temporary / "key.pem"
    public = temporary / "public.pem"
    subprocess.run(["openssl", "genpkey", "-quiet", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048", "-out", key], check=True)
    subprocess.run(["openssl", "pkey", "-in", key, "-pubout", "-out", public], check=True, stdout=subprocess.DEVNULL)
    manifest = fixture / "native-artifacts.json"
    args = types.SimpleNamespace(
        output=str(manifest),
        version="0.0.1",
        tag="v0.0.1",
        repository=native.CANONICAL_REPOSITORY,
        source_sha="1" * 40,
        builder_repository=native.CANONICAL_GITHUB_REPOSITORY,
        workflow=native.NATIVE_WORKFLOW,
        run_id=7,
        run_attempt=1,
        artifact=[f"{target}={archives[target]}" for target in native.NATIVE_TARGET_FILENAMES],
    )
    native.create_manifest(args)
    incomplete = types.SimpleNamespace(**vars(args))
    incomplete.output = str(temporary / "incomplete-native-artifacts.json")
    incomplete.artifact = [f"x86_64-unknown-linux-gnu={archive}"]
    rejected(lambda: native.create_manifest(incomplete), "incomplete native target inventory")
    signature = fixture / "native-artifacts.json.sig"
    subprocess.run(["openssl", "dgst", "-sha256", "-sign", key, "-out", signature, manifest], check=True)
    native.verify_release(
        manifest,
        signature,
        public,
        fixture,
        strict=True,
        expected_run_id=7,
        expected_run_attempt=1,
    )
    provenance = fixture / native.PROVENANCE_FILENAME
    provenance.write_text('{"fixture":"sigstore"}\n')
    native.verify_release(
        manifest,
        signature,
        public,
        fixture,
        strict=True,
        expected_run_id=7,
        expected_run_attempt=1,
        provenance_bundle=provenance,
    )
    subjects = native.attestation_subjects(native.load_manifest(manifest), manifest, signature, fixture)
    assert native.expected_attestation_subjects(native.load_manifest(manifest), manifest, signature) == subjects
    verification = [{
        "verificationResult": {
            "signature": {
                "certificate": {
                    "subjectAlternativeName": native.NATIVE_CERT_IDENTITY,
                    "buildSignerURI": native.NATIVE_CERT_IDENTITY,
                    "buildSignerDigest": "1" * 40,
                    "runnerEnvironment": "github-hosted",
                    "sourceRepositoryURI": native.CANONICAL_REPOSITORY,
                    "sourceRepositoryDigest": "1" * 40,
                    "sourceRepositoryRef": "refs/heads/main",
                    "buildConfigURI": native.NATIVE_CERT_IDENTITY,
                    "buildConfigDigest": "1" * 40,
                    "buildTrigger": "push",
                    "runInvocationURI": "https://github.com/hopmesh/monorepo/actions/runs/7/attempts/1",
                }
            },
            "statement": {
                "subject": subjects,
                "predicateType": native.SLSA_PROVENANCE_TYPE,
                "predicate": {
                    "buildDefinition": {
                        "buildType": native.GITHUB_WORKFLOW_BUILD_TYPE,
                        "externalParameters": {
                            "workflow": {
                                "ref": "refs/heads/main",
                                "repository": native.CANONICAL_REPOSITORY,
                                "path": native.NATIVE_WORKFLOW,
                            }
                        },
                        "internalParameters": {
                            "github": {
                                "event_name": "push",
                                "runner_environment": "github-hosted",
                            }
                        },
                        "resolvedDependencies": [{
                            "uri": f"git+{native.CANONICAL_REPOSITORY}@refs/heads/main",
                            "digest": {"gitCommit": "1" * 40},
                        }],
                    },
                    "runDetails": {
                        "builder": {"id": native.NATIVE_CERT_IDENTITY},
                        "metadata": {
                            "invocationId": "https://github.com/hopmesh/monorepo/actions/runs/7/attempts/1"
                        },
                    },
                },
            }
        }
    }]
    native.validate_provenance_result(native.load_manifest(manifest), subjects, verification)
    original_run = native.subprocess.run
    captured_command = []
    try:
        def fake_run(command, **_kwargs):
            captured_command.extend(command)
            return types.SimpleNamespace(returncode=0, stdout=json.dumps(verification), stderr="")

        native.subprocess.run = fake_run
        native.verify_sigstore_provenance(
            native.load_manifest(manifest),
            manifest,
            signature,
            provenance,
        )
    finally:
        native.subprocess.run = original_run
    assert captured_command[:3] == ["gh", "attestation", "verify"]
    assert "--bundle" in captured_command and "--deny-self-hosted-runners" in captured_command
    wrong_certificate = json.loads(json.dumps(verification))
    wrong_certificate[0]["verificationResult"]["signature"]["certificate"]["runInvocationURI"] = (
        "https://github.com/hopmesh/monorepo/actions/runs/7/attempts/2"
    )
    rejected(
        lambda: native.validate_provenance_result(
            native.load_manifest(manifest), subjects, wrong_certificate
        ),
        "wrong certificate run attempt",
    )
    wrong_provenance = json.loads(json.dumps(verification))
    wrong_provenance[0]["verificationResult"]["statement"]["predicate"]["buildDefinition"]["resolvedDependencies"][0]["digest"]["gitCommit"] = "2" * 40
    rejected(
        lambda: native.validate_provenance_result(native.load_manifest(manifest), subjects, wrong_provenance),
        "wrong provenance source",
    )
    missing_provenance = temporary / "missing-provenance"
    shutil.copytree(fixture, missing_provenance)
    (missing_provenance / provenance.name).unlink()
    rejected(
        lambda: native.verify_release(
            missing_provenance / manifest.name,
            missing_provenance / signature.name,
            public,
            missing_provenance,
            strict=True,
            provenance_bundle=missing_provenance / provenance.name,
        ),
        "missing provenance bundle",
    )
    linked_provenance = temporary / "linked-provenance"
    shutil.copytree(fixture, linked_provenance)
    (linked_provenance / provenance.name).unlink()
    (linked_provenance / provenance.name).symlink_to(linked_provenance / manifest.name)
    rejected(
        lambda: native.verify_release(
            linked_provenance / manifest.name,
            linked_provenance / signature.name,
            public,
            linked_provenance,
            strict=True,
            provenance_bundle=linked_provenance / provenance.name,
        ),
        "symlinked provenance bundle",
    )
    extracted = temporary / "extracted"
    selected = native.select_artifact(native.load_manifest(manifest), "x86_64-unknown-linux-gnu")
    native.safe_extract(native.verify_artifact(selected, fixture), extracted)
    assert (extracted / "lib/libhop.so").read_bytes() == b"fixture-libhop"

    rejected(lambda: native.select_artifact(native.load_manifest(manifest), "wrong-target"), "wrong target")
    missing = temporary / "missing"
    shutil.copytree(fixture, missing)
    (missing / archive.name).unlink()
    rejected(lambda: native.verify_release(missing / manifest.name, missing / signature.name, public, missing), "missing asset")
    rejected(lambda: native.verify_release(manifest, temporary / "absent.sig", public, fixture), "unsigned asset")
    rejected(
        lambda: native.verify_release(manifest, signature, public, fixture, expected_run_attempt=2),
        "wrong run attempt",
    )
    unexpected = temporary / "unexpected"
    shutil.copytree(fixture, unexpected)
    (unexpected / "extra.bin").write_bytes(b"extra")
    rejected(
        lambda: native.verify_release(
            unexpected / manifest.name,
            unexpected / signature.name,
            public,
            unexpected,
            strict=True,
            provenance_bundle=unexpected / provenance.name,
        ),
        "unexpected asset",
    )
    wrong_digest = temporary / "wrong-digest"
    shutil.copytree(fixture, wrong_digest)
    with (wrong_digest / archive.name).open("ab") as output_file:
        output_file.write(b"tamper")
    rejected(lambda: native.verify_release(wrong_digest / manifest.name, wrong_digest / signature.name, public, wrong_digest), "wrong SHA")

    duplicate = json.loads(manifest.read_text())
    duplicate["artifacts"].append(dict(duplicate["artifacts"][0]))
    rejected(lambda: native.validate_manifest(duplicate), "duplicate target")

    traversal = temporary / "traversal.tar.gz"
    with tarfile.open(traversal, "w:gz") as archive_file:
        info = tarfile.TarInfo("../escape")
        info.size = 1
        archive_file.addfile(info, io.BytesIO(b"x"))
    rejected(lambda: native.archive_entries(traversal), "path traversal")

    duplicate_archive = temporary / "duplicate.tar.gz"
    with tarfile.open(duplicate_archive, "w:gz") as archive_file:
        for payload in (b"a", b"b"):
            info = tarfile.TarInfo("lib/libhop.so")
            info.size = 1
            archive_file.addfile(info, io.BytesIO(payload))
    rejected(lambda: native.archive_entries(duplicate_archive), "duplicate archive path")

    oversized_zip = temporary / "oversized.zip"
    with zipfile.ZipFile(oversized_zip, "w") as archive_file:
        archive_file.writestr("payload", b"xx")
    original_expanded_limit = native.MAX_EXPANDED_BYTES
    native.MAX_EXPANDED_BYTES = 1
    try:
        rejected(lambda: native.safe_extract_zip(oversized_zip, temporary / "oversized-out"), "oversized GitHub artifact")
    finally:
        native.MAX_EXPANDED_BYTES = original_expanded_limit

# --- RETIRED WITH THE RUST CRATE MIRRORS (2026-08) ---------------------------------------------
# A ~120-line suite lived here pinning verify_standalone_lock's mid-release tolerance: the carve-out
# that lets a coordinated version bump pass CI while a first-party sibling is briefly absent from
# crates.io. It pinned everything that carve-out must still REJECT, because a check that quietly
# accepts a broken lock is worse than the deadlock it replaced.
#
# It is removed rather than adapted because it is now unreachable: verify_standalone_lock is only
# invoked for RUST_MIRRORS, which is empty, and the suite keyed off CRATE_RENAMES, which is also
# empty. Faking both to keep the test running would assert against a configuration the repo does not
# have. If a Rust crate is ever mirrored again, restore this suite in the same change: the tolerance
# is a deliberate hole in a safety check and must not go back unpinned.

print("package export and native artifact tests passed")
PY
