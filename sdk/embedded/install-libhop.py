#!/usr/bin/env python3
"""Install signed exact-target archives for an Embedded source checkout."""

import argparse
import importlib.util
import re
import shutil
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


REPOSITORY = "hopmesh/hop-embedded"
TAG_RE = re.compile(r"^v[0-9]+\.[0-9]+\.[0-9]+$")
TARGETS = (
    "xtensa-esp32-espidf",
    "xtensa-esp32s2-espidf",
    "xtensa-esp32s3-espidf",
    "riscv32imc-esp-espidf",
    "riscv32imac-esp-espidf",
)


def fail(message):
    raise SystemExit(f"embedded libhop install rejected: {message}")


def download(url, destination):
    request = urllib.request.Request(url, headers={"User-Agent": "hop-embedded-installer/1"})
    try:
        with urllib.request.urlopen(request, timeout=120) as response, Path(destination).open("wb") as output:
            host = urllib.parse.urlparse(response.url).hostname
            if host not in ("github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"):
                fail(f"release download redirected to an unexpected host: {host}")
            shutil.copyfileobj(response, output)
    except (urllib.error.HTTPError, urllib.error.URLError, OSError) as error:
        fail(f"download failed for {url}: {error}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", default="v0.0.1")
    parser.add_argument("--target", action="append", choices=TARGETS)
    parser.add_argument("--bundle")
    args = parser.parse_args()
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
            if args.bundle:
                bundle = Path(args.bundle).resolve()
            else:
                bundle = temporary / "release"
                bundle.mkdir()
                base = f"https://github.com/{REPOSITORY}/releases/download/{args.version}"
                download(base + "/native-artifacts.json", bundle / "native-artifacts.json")
                download(base + "/native-artifacts.json.sig", bundle / "native-artifacts.json.sig")
                helper.verify_signature(
                    bundle / "native-artifacts.json",
                    bundle / "native-artifacts.json.sig",
                    public_key,
                )
                manifest = helper.load_manifest(bundle / "native-artifacts.json")
                if manifest["tag"] != args.version:
                    fail("signed manifest tag does not match the requested version")
                for target in selected_targets:
                    artifact = helper.select_artifact(manifest, target)
                    download(base + "/" + artifact["filename"], bundle / artifact["filename"])
            manifest_path = bundle / "native-artifacts.json"
            signature_path = bundle / "native-artifacts.json.sig"
            helper.verify_signature(manifest_path, signature_path, public_key)
            manifest = helper.load_manifest(manifest_path)
            if manifest["tag"] != args.version:
                fail("signed manifest tag does not match the requested version")
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
            print(f"installed {len(selected_targets)} signed embedded target archive(s) in {artifacts_dir}")
    except (helper.ArtifactError, OSError, ValueError) as error:
        fail(str(error))


if __name__ == "__main__":
    main()
