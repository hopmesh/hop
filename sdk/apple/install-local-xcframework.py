#!/usr/bin/env python3
"""Install the signed release xcframework for Package.local.swift."""

import argparse
import hashlib
import importlib.util
import re
import shutil
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


REPOSITORY = "hopmesh/hop-sdk-apple"
TAG_RE = re.compile(r"^v[0-9]+\.[0-9]+\.[0-9]+$")


def fail(message):
    raise SystemExit(f"xcframework install rejected: {message}")


def download(url, destination):
    request = urllib.request.Request(url, headers={"User-Agent": "hop-sdk-apple-installer/1"})
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
    parser.add_argument("--bundle")
    args = parser.parse_args()
    if not TAG_RE.fullmatch(args.version):
        fail("version must be an exact vX.Y.Z tag")
    root = Path(__file__).resolve().parent
    helper_path = root / "native/native-artifacts.py"
    spec = importlib.util.spec_from_file_location("hop_native_artifacts", helper_path)
    if spec is None or spec.loader is None:
        fail("native artifact verifier is missing")
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    public_key = root / "native/native-artifacts-public.pem"
    try:
        with tempfile.TemporaryDirectory(prefix="hop-apple-install-") as temporary:
            temporary = Path(temporary)
            if args.bundle:
                bundle = Path(args.bundle).resolve()
            else:
                bundle = temporary / "release"
                bundle.mkdir()
                base = f"https://github.com/{REPOSITORY}/releases/download/{args.version}"
                manifest_path = bundle / "native-artifacts.json"
                signature_path = bundle / "native-artifacts.json.sig"
                download(base + "/native-artifacts.json", manifest_path)
                download(base + "/native-artifacts.json.sig", signature_path)
                helper.verify_signature(manifest_path, signature_path, public_key)
                manifest = helper.load_manifest(manifest_path)
                if manifest["tag"] != args.version:
                    fail("signed manifest tag does not match the requested version")
                artifact = helper.select_artifact(manifest, "apple-xcframework")
                download(base + "/" + artifact["filename"], bundle / artifact["filename"])
            manifest_path = bundle / "native-artifacts.json"
            signature_path = bundle / "native-artifacts.json.sig"
            manifest = helper.verify_release(
                manifest_path,
                signature_path,
                public_key,
                bundle,
                "apple-xcframework",
            )
            if manifest["tag"] != args.version:
                fail("signed manifest tag does not match the requested version")
            artifact = helper.select_artifact(manifest, "apple-xcframework")
            archive = bundle / artifact["filename"]
            published = (root / "Package.swift").read_text(encoding="utf-8")
            matches = re.findall(r'checksum:\s*"([0-9a-f]{64})"', published)
            if len(matches) != 1 or hashlib.sha256(archive.read_bytes()).hexdigest() != matches[0]:
                fail("verified archive does not match Package.swift checksum")
            frameworks = root / "Frameworks"
            if frameworks.exists():
                shutil.rmtree(frameworks)
            helper.safe_extract(archive, frameworks)
            xcframework = frameworks / "libhop.xcframework"
            helper_value = helper.apple_architecture_value(xcframework)
            architecture_path = xcframework / "architecture-manifest.json"
            if __import__("json").loads(architecture_path.read_text(encoding="utf-8")) != helper_value:
                fail("xcframework architecture manifest is invalid")
            print(f"installed verified {artifact['filename']} in {frameworks}")
    except (helper.ArtifactError, OSError, ValueError) as error:
        fail(str(error))


if __name__ == "__main__":
    main()
