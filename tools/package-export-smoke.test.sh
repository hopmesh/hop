#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$root" <<'PY'
import argparse
import importlib.util
import io
import json
import os
import pathlib
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
assert len(components) == 21
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

    elixir = (output / "hop-sdk-elixir").resolve()
    assert (elixir / "native/Cargo.toml").is_file()
    assert (elixir / "native/Cargo.lock").is_file()
    assert (elixir / "native/Cargo.lock").read_bytes() == (root / "tools/copybara/elixir-native-Cargo.lock").read_bytes()
    assert not (elixir / "native/hop_endpoint/Cargo.lock").exists()
    nif_manifest = (elixir / "native/hop_endpoint/Cargo.toml").read_text()
    assert 'hop = { workspace = true }' in nif_manifest
    assert "../../../../core/hop" not in nif_manifest
    assert "validate-elixir-export --export ." in (elixir / ".github/workflows/release.yml").read_text()
    declared = exports.elixir_declared_cargo_manifests(elixir)
    assert elixir / "native/vendor/libhop/Cargo.toml" in declared

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
    assert "releases/download/v0.0.1/libhop.xcframework.zip" in apple_manifest
    assert '.binaryTarget(name: "CHop", path:' not in apple_manifest
    assert (apple / "Package.local.swift").is_file()

    android = output / "hop-sdk-android"
    assert os.access(android / "build-aar.sh", os.X_OK)
    assert (android / "build-aar.sh").is_file()
    assert (android / "include/hop.h").is_file()
    android_build = (android / "build.gradle.kts").read_text()
    assert "hopAar" in android_build
    assert android_build.count('+ "\\n"') == 3
    assert r'}\n"""' not in android_build
    assert 'package="sh.hop"' in (android / "src/main/AndroidManifest.xml").read_text()
    android_release = (android / ".github/workflows/release.yml").read_text()
    assert "validate-android-export" in android_release
    assert "android-actions/setup-android@40fd30fb8d7440372e1316f5d1809ec01dcd3699" in android_release
    assert "gradle-version: '9.5.1'" in android_release

    android_consumer = temporary / "android-consumer-template"
    exports.write_android_application(
        android_consumer,
        'implementation("sh.hop:hop:0.0.1")',
        "package example.clean\nimport android.app.Activity\nimport sh.hop.HopAddress\n"
        "class MainActivity : Activity() { val address = HopAddress.base58(ByteArray(32)) }\n",
        temporary / "android-maven",
        "0.0.1",
    )
    android_consumer_text = "\n".join(
        path.read_text() for path in sorted(android_consumer.rglob("*")) if path.is_file()
    )
    assert android_consumer_text.count("implementation(") == 1
    assert 'implementation("sh.hop:hop:0.0.1")' in android_consumer_text
    assert 'id("com.android.application") version "9.2.1"' in android_consumer_text
    assert 'id("org.jetbrains.kotlin.android") version "2.4.0"' in android_consumer_text
    helper_source = (root / "tools/package-export-smoke.py").read_text()
    for forbidden in ("zipTree(hopAar.singleFile)", 'include("classes.jar")', "hopAar by configurations", "hop-aar/classes.jar"):
        assert forbidden not in helper_source
    for forbidden in ("zipTree(", "implementation(files(", 'include("classes.jar")', "hopAar by configurations"):
        assert forbidden not in android_release
        assert forbidden not in android_consumer_text
    assert "includeBuild(" not in android_consumer_text
    assert "project(" not in android_consumer_text

    android_readme = (android / "README.md").read_text()
    assert "public v0.0.1 publication remains post-merge external state" in android_readme.lower()
    assert "search.maven.org" not in android_readme
    assert "maven-central" not in android_readme

    embedded = output / "hop-embedded"
    assert os.access(embedded / "install-libhop.py", os.X_OK)
    embedded_exports = json.loads((embedded / "library.json").read_text())["export"]["include"]
    assert "native" in embedded_exports and "install-libhop.py" in embedded_exports
    embedded_linker = (embedded / "link-libhop.py").read_text()
    assert "native-artifacts.py" in embedded_linker
    assert "env.Append(LIBS=[env.File(archive)])" in embedded_linker
    assert "env.Append(LINKFLAGS=[archive])" not in embedded_linker

    native_workflow = (root / ".github/workflows/native-artifacts.yml").read_text()
    for target in (
        "xtensa-esp32-espidf",
        "xtensa-esp32s2-espidf",
        "xtensa-esp32s3-espidf",
        "riscv32imc-esp-espidf",
        "riscv32imac-esp-espidf",
    ):
        assert target in native_workflow
    assert native_workflow.count("-Zbuild-std=std,panic_abort") == 1
    esp_release = (root / ".github/workflows/libhop-esp-release.yml").read_text()
    assert esp_release.count("-Zbuild-std=std,panic_abort") == 2
    esp_builder = (root / "apps/esp32/hop-sensor/build-libhop-esp.sh").read_text()
    assert "cargo +esp build" in esp_builder
    assert esp_builder.count("-Zbuild-std=std,panic_abort") == 1

    fixture = temporary / "fixture"
    fixture.mkdir()
    stage = temporary / "stage"
    (stage / "lib").mkdir(parents=True)
    (stage / "include").mkdir()
    (stage / "lib/libhop.so").write_bytes(b"fixture-libhop")
    (stage / "include/hop.h").write_bytes(b"#define HOP_ABI_VERSION 4\n")
    archive = fixture / "libhop-x86_64-unknown-linux-gnu.tar.gz"
    native.pack_archive(stage, [], archive, "tar.gz")
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
        artifact=[f"x86_64-unknown-linux-gnu={archive}"],
    )
    native.create_manifest(args)
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
    rejected(lambda: native.verify_release(unexpected / manifest.name, unexpected / signature.name, public, unexpected, strict=True), "unexpected asset")
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

print("package export and native artifact tests passed")
PY
