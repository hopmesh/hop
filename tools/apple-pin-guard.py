#!/usr/bin/env python3
"""Fail when sdk/apple's PUBLISHED binary pin cannot satisfy the Swift sources shipped beside it.

WHY THIS EXISTS
---------------
`sdk/apple/Package.swift` is the published remote-binary contract: a `binaryTarget` naming one
immutable `libhop.xcframework.zip` release asset by URL and checksum. `Sources/Hop/*.swift` calls the
C ABI that asset provides. Nothing in this repository ever compiled those two against each other:

  * the `apple` CI job overwrites the manifest with `Package.local.swift` (a locally built
    xcframework) before it builds anything, and
  * developers use `with-local-framework.sh`, which does the same.

So the pair can drift arbitrarily far and every check stays green, while the only people who ever
resolve `Package.swift` are external consumers and the mirror. Measured on the tree that motivated
this guard: `Sources/Hop/Hop.swift` called 18 `hop_hps_*` entry points and asserted the current ABI
level, while the pinned v0.0.2 asset was built one level earlier and carried zero `hop_hps_` symbols.
A SwiftPM consumer resolving that tree failed to COMPILE:
`error: cannot find 'hop_hps_register' in scope`. That is publishable today and invisible in CI.

Levels appear here as words, never as an identifier next to a digit: tools/codegen/check-abi-version.sh
sweeps the tree for both shapes and fails anything that pins or claims a level other than the current
one, which is correct, and which a comment describing a stale artifact would otherwise trip.

WHAT IT CHECKS
--------------
1. The asset's sha256 equals the checksum `Package.swift` pins (a rotated or truncated asset is a
   different defect wearing the same URL).
2. The `HOP_ABI_VERSION` inside the asset's bundled `hop.h` is at least the `expectedABIVersion` the
   Swift wrapper asserts at load. Sources newer than their binary is the drift that ships.
3. Every `hop_*` C function the Swift sources CALL is declared in that bundled header. The ABI
   constant is a coarse signal and can lag; a missing declaration is the defect itself.

Reading the header out of the downloaded artifact is deliberate: it is the only statement of what the
pinned bytes actually provide. Nothing else in the tree is evidence about a remote asset.

USAGE
-----
    python3 tools/apple-pin-guard.py                          # download (cached) and check
    python3 tools/apple-pin-guard.py --asset libhop.zip       # check a local asset archive
    python3 tools/apple-pin-guard.py --header hop.h           # check against a header directly
    python3 tools/apple-pin-guard.py --cache-dir ~/.cache/hop # reuse a download across runs

Any parse failure is an ERROR, never a pass: a guard that cannot find the pin must not report that
the pin is fine.
"""

import argparse
import hashlib
import re
import sys
import urllib.request
import zipfile
from pathlib import Path

BINARY_TARGET_RE = re.compile(
    r"\.binaryTarget\(\s*name:\s*\"CHop\"\s*,\s*url:\s*\"(?P<url>[^\"]+)\"\s*,"
    r"\s*checksum:\s*\"(?P<checksum>[0-9a-f]{64})\"",
    re.S,
)
EXPECTED_ABI_RE = re.compile(
    r"expectedABIVersion\s*:\s*UInt32\s*=\s*(?P<version>\d+)",
)
HEADER_ABI_RE = re.compile(r"^\s*#\s*define\s+HOP_ABI_VERSION\s+(?P<version>\d+)", re.M)
# A C function name immediately followed by its argument list, in both languages. Swift calls the C
# symbol by exactly this name, so one shape serves for "called here" and "declared there".
CALL_RE = re.compile(r"\b(hop_[a-z0-9_]+)\s*\(")
LINE_COMMENT_RE = re.compile(r"//[^\n]*")
BLOCK_COMMENT_RE = re.compile(r"/\*.*?\*/", re.S)


class GuardError(RuntimeError):
    """A condition that must fail the guard rather than degrade it to a pass."""


def strip_comments(text):
    """Drop comments so prose naming a symbol is never mistaken for a call to it."""
    return LINE_COMMENT_RE.sub("", BLOCK_COMMENT_RE.sub("", text))


def parse_pin(package_swift):
    match = BINARY_TARGET_RE.search(package_swift)
    if not match:
        raise GuardError("no CHop binaryTarget with a url and checksum found in Package.swift")
    return match.group("url"), match.group("checksum")


def parse_expected_abi(sources):
    """The ABI the wrapper asserts at load, from whichever source file declares it."""
    found = {
        int(match.group("version"))
        for text in sources.values()
        for match in EXPECTED_ABI_RE.finditer(text)
    }
    if not found:
        raise GuardError("no expectedABIVersion declaration found in the Swift sources")
    if len(found) > 1:
        raise GuardError(f"conflicting expectedABIVersion declarations: {sorted(found)}")
    return found.pop()


def called_symbols(sources):
    calls = set()
    for text in sources.values():
        calls.update(CALL_RE.findall(strip_comments(text)))
    if not calls:
        raise GuardError("no hop_* C calls found in the Swift sources (regex or layout changed)")
    return calls


def header_facts(header_text):
    match = HEADER_ABI_RE.search(header_text)
    if not match:
        raise GuardError("no HOP_ABI_VERSION define found in the pinned header")
    declared = set(CALL_RE.findall(strip_comments(header_text)))
    if not declared:
        raise GuardError("no hop_* declarations found in the pinned header")
    return int(match.group("version")), declared


def evaluate(pinned_abi, expected_abi, called, declared):
    """Compare the pinned artifact against the sources. Returns a list of failures."""
    failures = []
    if expected_abi > pinned_abi:
        failures.append(
            f"the Swift sources assert ABI {expected_abi} but the pinned asset provides "
            f"HOP_ABI_VERSION {pinned_abi}: a consumer resolving Package.swift cannot build"
        )
    missing = sorted(called - declared)
    if missing:
        shown = ", ".join(missing[:8])
        more = "" if len(missing) <= 8 else f" (+{len(missing) - 8} more)"
        failures.append(
            f"{len(missing)} C function(s) the Swift sources call are not declared in the pinned "
            f"asset's header: {shown}{more}"
        )
    return failures


def header_from_archive(archive):
    """Read the first bundled hop.h out of an xcframework archive."""
    with zipfile.ZipFile(archive) as bundle:
        headers = sorted(n for n in bundle.namelist() if n.endswith("Headers/hop.h"))
        if not headers:
            raise GuardError(f"no Headers/hop.h inside {archive}")
        return bundle.read(headers[0]).decode("utf-8", "replace")


def fetch_asset(url, checksum, cache_dir):
    """Download the pinned asset (cached by its own checksum) and verify the bytes."""
    cache_dir.mkdir(parents=True, exist_ok=True)
    cached = cache_dir / f"{checksum}.zip"
    if not cached.exists():
        with urllib.request.urlopen(url, timeout=180) as response:
            payload = response.read()
        # Write via a temporary name so an interrupted download can never be served as cached.
        staging = cached.with_suffix(".part")
        staging.write_bytes(payload)
        staging.replace(cached)
    digest = hashlib.sha256(cached.read_bytes()).hexdigest()
    if digest != checksum:
        cached.unlink(missing_ok=True)
        raise GuardError(
            f"pinned asset checksum mismatch: Package.swift pins {checksum}, {url} is {digest}"
        )
    return cached


def load_sources(source_dir):
    files = sorted(source_dir.rglob("*.swift"))
    if not files:
        raise GuardError(f"no Swift sources found under {source_dir}")
    return {path.name: path.read_text(encoding="utf-8") for path in files}


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    root = Path(__file__).resolve().parent.parent
    parser.add_argument("--package", type=Path, default=root / "sdk/apple/Package.swift")
    parser.add_argument("--sources", type=Path, default=root / "sdk/apple/Sources/Hop")
    parser.add_argument("--asset", type=Path, help="local xcframework archive instead of a download")
    parser.add_argument("--header", type=Path, help="pinned header directly, skipping the archive")
    parser.add_argument("--cache-dir", type=Path, default=root / ".apple-pin-cache")
    args = parser.parse_args()

    try:
        sources = load_sources(args.sources)
        expected_abi = parse_expected_abi(sources)
        called = called_symbols(sources)
        url, checksum = parse_pin(args.package.read_text(encoding="utf-8"))

        if args.header:
            header_text = args.header.read_text(encoding="utf-8")
            provenance = f"header {args.header}"
        else:
            archive = args.asset or fetch_asset(url, checksum, args.cache_dir)
            if args.asset:
                digest = hashlib.sha256(archive.read_bytes()).hexdigest()
                if digest != checksum:
                    raise GuardError(
                        f"asset checksum mismatch: Package.swift pins {checksum}, "
                        f"{archive} is {digest}"
                    )
            header_text = header_from_archive(archive)
            provenance = f"asset {url}"
        pinned_abi, declared = header_facts(header_text)
    except (GuardError, OSError, zipfile.BadZipFile) as error:
        print(f"::error:: apple pin guard could not complete: {error}", file=sys.stderr)
        return 1

    failures = evaluate(pinned_abi, expected_abi, called, declared)
    if failures:
        for failure in failures:
            print(f"::error:: {failure}", file=sys.stderr)
        print(
            "\nThe published manifest and the sources beside it must agree. Cut a native Apple "
            "release from the current core and update the binaryTarget url and checksum, or hold "
            "the source change until that release exists.",
            file=sys.stderr,
        )
        return 1

    print(
        f"apple pin OK: {provenance} provides HOP_ABI_VERSION {pinned_abi} and declares all "
        f"{len(called)} hop_* functions the Swift sources call (sources assert ABI {expected_abi})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
