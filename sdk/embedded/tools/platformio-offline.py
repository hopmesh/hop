#!/usr/bin/env python3
"""Fetch hash-locked PlatformIO inputs and render a local-only project config."""

import argparse
import hashlib
import json
import os
import re
import shutil
import tempfile
import urllib.parse
import urllib.request
from pathlib import Path


SHA_RE = re.compile(r"^[0-9a-f]{64}$")
REF_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[A-Za-z0-9.+_-]+$")
DOWNLOAD_HOSTS = {"dl.registry.platformio.org", "usc1.contabostorage.com"}


class OfflineError(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise OfflineError(message)


def sha256(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def load_lock(path):
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    require(set(data) == {"packages", "schema", "system"}, "lock fields are invalid")
    require(data["schema"] == 1, "lock schema is unsupported")
    require(data["system"] == "linux_x86_64", "lock system is unsupported")
    require(isinstance(data["packages"], list) and data["packages"], "lock is empty")
    references = set()
    filenames = set()
    platform_count = 0
    for entry in data["packages"]:
        require(
            set(entry) == {"filename", "kind", "metadata", "reference", "sha256", "url"},
            "locked package fields are invalid",
        )
        require(entry["kind"] in ("platform", "package"), "locked package kind is invalid")
        platform_count += entry["kind"] == "platform"
        require(REF_RE.fullmatch(entry["reference"]), "locked package reference is invalid")
        require(SHA_RE.fullmatch(entry["sha256"]), "locked package digest is invalid")
        require(
            urllib.parse.urlparse(entry["url"]).scheme == "https"
            and urllib.parse.urlparse(entry["url"]).hostname in DOWNLOAD_HOSTS,
            "locked package download URL is not an approved immutable input",
        )
        require(
            urllib.parse.urlparse(entry["metadata"]).scheme == "https"
            and urllib.parse.urlparse(entry["metadata"]).hostname == "api.registry.platformio.org",
            "locked package checksum metadata source is invalid",
        )
        require(Path(entry["filename"]).name == entry["filename"], "locked filename is unsafe")
        require(entry["reference"] not in references, "locked package reference is duplicated")
        require(entry["filename"] not in filenames, "locked package filename is duplicated")
        references.add(entry["reference"])
        filenames.add(entry["filename"])
    require(platform_count == 1, "lock must contain exactly one platform")
    return data


def download(entry, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.is_file() and sha256(destination) == entry["sha256"]:
        return
    temporary = Path(
        tempfile.mkstemp(prefix=entry["filename"] + ".", dir=destination.parent)[1]
    )
    try:
        request = urllib.request.Request(
            entry["url"], headers={"User-Agent": "hop-platformio-offline/1"}
        )
        with urllib.request.urlopen(request, timeout=120) as response, temporary.open("wb") as output:
            require(
                urllib.parse.urlparse(response.geturl()).hostname in DOWNLOAD_HOSTS,
                "package download redirected to an unapproved host",
            )
            shutil.copyfileobj(response, output)
        require(sha256(temporary) == entry["sha256"], f"digest mismatch: {entry['filename']}")
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)


def fetch(lock, cache):
    cache.mkdir(parents=True, exist_ok=True)
    for entry in lock["packages"]:
        download(entry, cache / entry["filename"])
    print(f"verified PlatformIO cache: packages={len(lock['packages'])} path={cache}")


def config_references(text):
    references = []
    in_packages = False
    for raw in text.splitlines():
        line = raw.split(";", 1)[0].rstrip()
        platform = re.match(r"^\s*platform\s*=\s*(\S+)\s*$", line)
        if platform:
            references.append(platform.group(1))
            in_packages = False
            continue
        if re.match(r"^\s*platform_packages\s*=\s*$", line):
            in_packages = True
            continue
        if in_packages and raw[:1].isspace() and line.strip() and "=" not in line:
            references.append(line.strip())
            continue
        if line.strip():
            in_packages = False
    return references


def config_uri(path):
    value = Path(path).resolve().as_posix()
    require(re.fullmatch(r"/[A-Za-z0-9_./+:-]+", value), "PlatformIO cache path is not URI-safe")
    return "file://" + value


def local_reference(entry, path):
    uri = config_uri(path)
    if entry["kind"] == "platform":
        return uri
    package = entry["reference"].split("@", 1)[0]
    return f"{package} @ {uri}"


def render(lock, cache, source, output):
    text = source.read_text(encoding="utf-8")
    locked = {entry["reference"]: entry for entry in lock["packages"]}
    references = config_references(text)
    require(len(references) == len(set(references)), "PlatformIO config has duplicate inputs")
    require(set(references) == set(locked), "PlatformIO config and package lock differ")
    for reference, entry in locked.items():
        archive = cache / entry["filename"]
        require(archive.is_file(), f"verified archive is absent: {entry['filename']}")
        require(sha256(archive) == entry["sha256"], f"cached digest changed: {entry['filename']}")
        text = text.replace(reference, local_reference(entry, archive))
    require(not any(reference in text for reference in locked), "registry input remains in config")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(text, encoding="utf-8")
    print(f"rendered offline PlatformIO config: {output}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("fetch", "config", "verify"))
    parser.add_argument("--lock", default="platformio-packages.lock.json")
    parser.add_argument("--cache")
    parser.add_argument("--input")
    parser.add_argument("--output")
    args = parser.parse_args()
    try:
        lock = load_lock(args.lock)
        if args.command == "verify":
            print(f"PlatformIO lock verified: packages={len(lock['packages'])}")
            return
        require(args.cache is not None, "--cache is required")
        cache = Path(args.cache).resolve()
        if args.command == "fetch":
            fetch(lock, cache)
            return
        require(args.input is not None and args.output is not None, "--input and --output are required")
        render(lock, cache, Path(args.input), Path(args.output))
    except (OfflineError, OSError, ValueError, json.JSONDecodeError) as error:
        raise SystemExit(f"PlatformIO offline input rejected: {error}") from error


if __name__ == "__main__":
    main()
