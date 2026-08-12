#!/usr/bin/env python3
"""Install signed exact-target archives for an Embedded source checkout from a local bundle."""

import argparse
import importlib.util
import re
import shutil
import tempfile
from pathlib import Path


TAG_RE = re.compile(r"^v[0-9]+\.[0-9]+\.[0-9]+$")
TARGETS = (
    "xtensa-esp32-espidf",
    "xtensa-esp32s2-espidf",
    "xtensa-esp32s3-espidf",
    "riscv32imc-esp-espidf",
    "riscv32imac-esp-espidf",
)
NO_BUNDLE_MESSAGE = (
    "--bundle is required. There is no published prebuilt libhop bundle for embedded targets, so "
    "there is nothing to download; the remote install path has been removed rather than pointed at "
    "a URL that serves no releases. The supported path is to build the exact-target archives "
    "locally and pass the signed bundle directory: install-libhop.py --bundle "
    "/path/to/release-assets. tools/native-artifacts.py in the Hop monorepo produces that bundle "
    "(pack one archive per target, then create and sign native-artifacts.json next to its .sig and "
    "Sigstore provenance). This installer still verifies every one of those before staging."
)


def fail(message):
    raise SystemExit(f"embedded libhop install rejected: {message}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", default="v0.0.1")
    parser.add_argument("--target", action="append", choices=TARGETS)
    parser.add_argument("--bundle", help="required: directory holding the signed native release bundle")
    args = parser.parse_args()
    if not args.bundle:
        fail(NO_BUNDLE_MESSAGE)
    if not TAG_RE.fullmatch(args.version):
        fail("version must be an exact vX.Y.Z tag")
    selected_targets = tuple(args.target or TARGETS)
    if len(set(selected_targets)) != len(selected_targets):
        fail("target selection contains a duplicate")
    root = Path(__file__).resolve().parent
    native_dir = root / "native"
    helper_path = native_dir / "native-artifacts.py"
    spec = importlib.util.spec_from_file_location("hop_native_artifacts", helper_path)
    if spec is None or spec.loader is None:
        fail("native artifact verifier is missing")
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    public_key = native_dir / "native-artifacts-public.pem"
    try:
        with tempfile.TemporaryDirectory(prefix="hop-embedded-install-") as temporary:
            temporary = Path(temporary)
            bundle = Path(args.bundle).resolve()
            manifest_path = bundle / "native-artifacts.json"
            signature_path = bundle / "native-artifacts.json.sig"
            provenance_path = bundle / "native-artifacts.provenance.sigstore.json"
            helper.verify_signature(manifest_path, signature_path, public_key)
            manifest = helper.load_manifest(manifest_path)
            if manifest["tag"] != args.version:
                fail("signed manifest tag does not match the requested version")
            helper.verify_sigstore_provenance(
                manifest,
                manifest_path,
                signature_path,
                provenance_path,
            )
            staged_artifacts = temporary / "artifacts"
            staged_artifacts.mkdir()
            for target in selected_targets:
                artifact = helper.select_artifact(manifest, target)
                helper.verify_artifact(artifact, bundle)
                shutil.copy2(bundle / artifact["filename"], staged_artifacts / artifact["filename"])
            artifacts_dir = native_dir / "artifacts"
            if artifacts_dir.exists():
                shutil.rmtree(artifacts_dir)
            shutil.copytree(staged_artifacts, artifacts_dir)
            shutil.copy2(manifest_path, native_dir / "native-artifacts.json")
            shutil.copy2(signature_path, native_dir / "native-artifacts.json.sig")
            shutil.copy2(provenance_path, native_dir / "native-artifacts.provenance.sigstore.json")
            print(f"installed {len(selected_targets)} signed embedded target archive(s) in {artifacts_dir}")
    except (helper.ArtifactError, OSError, ValueError) as error:
        fail(str(error))


if __name__ == "__main__":
    main()
