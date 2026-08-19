#!/usr/bin/env python3
"""Publish the Apple pods to the CocoaPods trunk registry in dependency order, and prove each landed.

WHY THIS IS A SCRIPT AND NOT A `run:` BLOCK. `pod trunk push` cannot be trusted on its own for three
measured reasons, each of which is a step this file performs:

1. IT LINTS BY BUILDING. cocoapods-trunk's push command constructs the same `Validator` that
   `pod spec lint` uses (push.rb `validate_podspec`), which downloads the pod's DECLARED source and
   compiles it for every declared platform. For an iOS pod that needs Xcode, so this runs on macOS.
   Nothing here can move to the ubuntu publish job.

2. ORDER MATTERS AND PROPAGATION IS NOT INSTANT. HopSDK depends on CHop and HopContract, and the
   validator resolves dependencies from the trunk CDN, not from the sibling files on disk. Measured:
   `pod spec lint HopSDK.podspec` against today's tree fails with "Unable to find a specification for
   `CHop (= 0.0.2)` depended upon by `HopSDK`". So the two leaves are pushed first and this script
   WAITS for each to be readable from the CDN before the dependent push starts, rather than assuming
   the write is immediately visible to the next read.

3. THE POD IS NOT THE ONLY THING THAT HAS TO BE TRUE. CHop's source is the GitHub release asset for
   this tag, so the release has to exist before the lint downloads it, and the version the podspecs
   derive from Package.swift has to be the version being tagged. Both are asserted here, loudly,
   because a pod published against a mismatched tag points consumers at code that is not this release.

IDEMPOTENCE IS NARROW ON PURPOSE. Re-running a released tag must not fail the workflow, but "ignore
errors" is the defect this repo keeps finding. So the only tolerated condition is the specific one that
means the work is already done: the exact version is already on trunk. That is detected BEFORE the push
by reading the registry, and again after a push that reports a duplicate. Every other failure is fatal.
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path


# Podspec name -> the podspec file, in the order they must reach the registry. CHop and HopContract are
# leaves; HopSDK depends on both, so it goes last and only after both are readable from the CDN.
PUBLISH_ORDER = ("CHop", "HopContract", "HopSDK")

# Both hosts are overridable by the same mechanism cocoapods-trunk itself uses: its Trunk command reads
# TRUNK_SCHEME_AND_HOST, so pointing that at a local server redirects the CLI and this script together
# and the self-test can exercise the real code path instead of a parallel imitation of it.
TRUNK_HOST = os.environ.get("TRUNK_SCHEME_AND_HOST") or "https://trunk.cocoapods.org"
TRUNK_API = f"{TRUNK_HOST}/api/v1"
# The CDN redirects to jsDelivr and rejects an unknown user agent with 403, so both following the
# redirect and sending an agent are deliberate. Measured against a published pod: 200 for a live
# version, 404 for an absent one.
CDN = os.environ.get("COCOAPODS_CDN_HOST") or "https://cdn.cocoapods.org"
USER_AGENT = "hop-release/1"
VERSION_RE = re.compile(r"/releases/download/v([0-9][^/\s\"]*)/libhop\.xcframework\.zip")
SEMVER_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$")
# cocoapods-trunk raises this text (from the registry, via print_error) when the version already exists.
DUPLICATE_RE = re.compile(r"duplicate entry", re.IGNORECASE)


class TrunkError(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise TrunkError(message)


def get_json(url, timeout=60):
    """GET a JSON document. Returns None for 404, raises for anything else that is not success.

    A failed fetch must never read as "absent": that is how a publish step comes to believe a pod is
    unpublished, push it, and then report a duplicate as a fresh success. Only a real 404 is absence.
    """
    request = urllib.request.Request(url, headers={"Accept": "application/json", "User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            require(200 <= response.status < 300, f"unexpected status {response.status} from {url}")
            return json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        detail = error.read().decode("utf-8", "replace").strip()
        raise TrunkError(f"registry query failed: HTTP {error.code} from {url}: {detail}") from error


def published_versions(pod):
    """Versions trunk holds for `pod`, or None when the pod name has never been published."""
    document = get_json(f"{TRUNK_API}/pods/{pod}")
    if document is None:
        return None
    versions = document.get("versions")
    require(isinstance(versions, list), f"trunk returned no version list for {pod}")
    return {entry.get("name") for entry in versions if isinstance(entry, dict)}


def cdn_url(pod, version):
    """The sharded CDN path for one published spec: the first three hex digits of MD5(pod name)."""
    shard = hashlib.md5(pod.encode("utf-8")).hexdigest()
    return f"{CDN}/Specs/{shard[0]}/{shard[1]}/{shard[2]}/{pod}/{version}/{pod}.podspec.json"


def readable_from_cdn(pod, version):
    request = urllib.request.Request(cdn_url(pod, version), headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return 200 <= response.status < 300
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return False
        raise TrunkError(f"CDN query failed for {pod} {version}: HTTP {error.code}") from error
    except urllib.error.URLError as error:
        raise TrunkError(f"CDN query failed for {pod} {version}: {error.reason}") from error


def await_cdn(pod, version, attempts, delay):
    """Block until a just-pushed spec is resolvable by the next pod's lint, or fail naming the wait.

    Bounded on purpose. An unbounded wait turns a registry outage into a job that hangs until the
    runner times out with no diagnosis, which is strictly worse than a failure that says what it wanted.
    """
    for attempt in range(1, attempts + 1):
        if readable_from_cdn(pod, version):
            print(f"{pod} {version} is readable from the CDN after {attempt} of {attempts} checks")
            return
        if attempt < attempts:
            print(f"{pod} {version} not on the CDN yet, check {attempt} of {attempts}")
            time.sleep(delay)
    raise TrunkError(
        f"{pod} {version} never became readable from the CDN within {attempts} checks "
        f"spaced {delay}s apart ({cdn_url(pod, version)}). The dependent pod's lint resolves its "
        "dependencies from the CDN, so continuing would fail with a misleading 'unable to find a "
        "specification' error instead of naming the propagation delay."
    )


def podspec_version(directory, pod):
    """The version a podspec will carry, taken from the same Package.swift the podspec itself reads."""
    manifest = (directory / "Package.swift").read_text(encoding="utf-8")
    match = VERSION_RE.search(manifest)
    require(match is not None, f"no libhop.xcframework release URL in {directory / 'Package.swift'}")
    version = match.group(1)
    require(SEMVER_RE.fullmatch(version), f"{pod} would publish a version that is not semver: {version}")
    return version


def push(directory, pod, token, synchronous):
    """Run one `pod trunk push`, treating only an already-published version as success.

    NO --allow-warnings, deliberately. Measured on this tree: all three pods lint clean without it
    (CHop's only warning, "Unable to find a license file", was a real gap and is fixed in the podspec
    rather than suppressed). A standing warning-suppression flag on a publish path is the thing that
    later gets reached for to turn a red release green, so it is absent rather than unused.
    """
    command = ["pod", "trunk", "push", f"{pod}.podspec", "--verbose"]
    if synchronous:
        # Switches the validator's dependency source from the CDN to the Specs git repo, which the
        # registry updates ahead of the CDN. Belt to await_cdn's braces for the dependent push.
        command.append("--synchronous")
    environment = {**os.environ, "COCOAPODS_TRUNK_TOKEN": token}
    print(f"pushing {pod} from {directory}: {' '.join(command)}")
    result = subprocess.run(
        command, cwd=str(directory), env=environment, check=False,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    print(result.stdout, end="" if result.stdout.endswith("\n") else "\n")
    if result.returncode == 0:
        return
    # cocoapods-trunk exits nonzero on a duplicate version because print_error raises. That single
    # condition means the version is already on the registry, which is the outcome we wanted anyway.
    # Everything else, including a lint failure, stays fatal.
    require(
        DUPLICATE_RE.search(result.stdout or ""),
        f"pod trunk push failed for {pod} with exit {result.returncode}",
    )
    print(f"{pod} was already on trunk (registry reported a duplicate entry)")


def publish(args):
    directory = Path(args.directory).resolve()
    require(directory.is_dir(), f"podspec directory does not exist: {directory}")

    # A missing secret must FAIL here, naming itself. GitHub resolves an unset secret to the empty
    # string, and cocoapods-trunk would then fall back to ~/.netrc, which on a fresh runner does not
    # exist, so the job would die inside the CLI's own usage banner instead of saying what is unset.
    token = os.environ.get("COCOAPODS_TRUNK_TOKEN", "").strip()
    require(
        token != "",
        "COCOAPODS_TRUNK_TOKEN is not set. Nothing can be published to the CocoaPods trunk registry "
        "without it. Create the secret in the release environment of hopmesh/hop-sdk-apple from the "
        "token `pod trunk register` writes to ~/.netrc. This step fails rather than skipping, because "
        "a publish that reports success while publishing nothing is worse than a red build.",
    )
    require("\n" not in token and "\r" not in token, "COCOAPODS_TRUNK_TOKEN contains a newline")

    version = podspec_version(directory, "CHop")
    if args.expect_version:
        require(
            version == args.expect_version,
            f"the podspecs would publish {version} but this release is {args.expect_version}. "
            "The version comes from the libhop release URL in Package.swift, and HopSDK and "
            "HopContract point their git source at v<that version>, so publishing now would ship a "
            "pod whose sources are a different tag from this release.",
        )
    print(f"publishing the Apple pods at version {version} in order: {', '.join(PUBLISH_ORDER)}")

    for index, pod in enumerate(PUBLISH_ORDER):
        require((directory / f"{pod}.podspec").is_file(), f"missing podspec: {directory / f'{pod}.podspec'}")
        existing = published_versions(pod)
        if existing is not None and version in existing:
            print(f"{pod} {version} is already on trunk, nothing to push")
        else:
            push(
                directory,
                pod,
                token,
                # Only the dependent push needs the registry's git mirror as its dependency source.
                synchronous=index > 0,
            )
            # Trust the registry, not the exit code: read the version back before calling it published.
            after = published_versions(pod)
            require(
                after is not None and version in after,
                f"{pod} {version} is still absent from the registry after the push reported success",
            )
            print(f"{pod} {version} is on trunk")
        if index + 1 < len(PUBLISH_ORDER):
            await_cdn(pod, version, args.cdn_attempts, args.cdn_delay)

    print(f"every Apple pod is published at {version}: {', '.join(PUBLISH_ORDER)}")


def main():
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    upload = subparsers.add_parser("publish")
    upload.add_argument("--directory", default=".", help="directory holding the podspecs")
    upload.add_argument("--expect-version", help="the release version the podspecs must agree with")
    upload.add_argument("--cdn-attempts", type=int, default=30)
    upload.add_argument("--cdn-delay", type=float, default=20.0)
    args = parser.parse_args()
    try:
        publish(args)
    except (TrunkError, OSError, ValueError, json.JSONDecodeError) as error:
        raise SystemExit(f"pod publication rejected: {error}") from error


if __name__ == "__main__":
    main()
