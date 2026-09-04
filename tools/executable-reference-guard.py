#!/usr/bin/env python3
"""Reject mutable executable dependencies in repository automation."""

import argparse
import json
import re
import subprocess
from pathlib import Path


SHA = r"[0-9a-f]{40}"
DIGEST = r"sha256:[0-9a-f]{64}"
USES_RE = re.compile(r"^\s*-?\s*uses:\s*([^\s#]+)(?:\s+#\s*(.+))?\s*$")
INLINE_USES_RE = re.compile(r"[{,]\s*uses:\s*([^\s,}\]#]+)")
IMAGE_RE = re.compile(rf"^[^\s@]+(?::[^\s@]+)?@{DIGEST}$")
PLATFORMIO_REF_RE = re.compile(
    r"^(?:[A-Za-z0-9_.-]+/)?[A-Za-z0-9_.-]+@"
    r"[0-9]+(?:\.[0-9]+){2,}(?:[-+][A-Za-z0-9._-]+)?$"
)
PUBLISH_RE = re.compile(
    r"cargo\s+publish|crates-publish\.py\s+publish|npm\s+publish|pio\s+pkg\s+publish|mix\s+hex\.publish|"
    r"\bgem\s+push\b|bundle\s+exec\s+rake\s+release|gh\s+release\s+create|"
    r"gh-action-pypi-publish@|softprops/action-gh-release@|hex\.pm/api/packages/|"
    r"publishHopPublicationToHopRepository|pod\s+trunk\s+push|trunk-publish\.py\s+publish"
)
BUILD_RE = re.compile(
    r"cargo\s+(?:build|test|package)|wasm-pack\s+build|npm\s+(?:ci|test|pack)|"
    r"python(?:3)?\s+-m\s+build|\bgem\s+build\b|mix\s+(?:compile|test|hex\.build)|"
    r"pio\s+(?:run|pkg\s+pack)|swift\s+(?:test|build|package\s+describe)|"
    r"crystal\s+(?:spec|tool\s+format)|go\s+(?:test|build)"
)


class PolicyError(RuntimeError):
    pass


def repository_files(root):
    result = subprocess.run(
        ["git", "-C", str(root), "rev-parse", "--is-inside-work-tree"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if result.returncode == 0:
        listed = subprocess.check_output(
            [
                "git",
                "-C",
                str(root),
                "ls-files",
                "-z",
                "--cached",
                "--others",
                "--exclude-standard",
            ]
        )
        return [root / path.decode("utf-8") for path in listed.split(b"\0") if path]
    return [path for path in root.rglob("*") if path.is_file()]


def is_workflow(path):
    posix = path.as_posix()
    return (
        "/.github/workflows/" in "/" + posix
        and path.suffix in (".yml", ".yaml")
    ) or (
        "/.github/actions/" in "/" + posix
        and path.name in ("action.yml", "action.yaml")
    )


def is_cloudbuild(path):
    return path.name.startswith("cloudbuild") and path.suffix in (".yml", ".yaml")


def is_dockerfile(path):
    return path.name == "Dockerfile" or path.name.startswith("Dockerfile.")


def is_terraform(path):
    return path.suffix == ".tf"


def active_lines(text):
    return [line for line in text.splitlines() if not line.lstrip().startswith("#")]


def logical_lines(text):
    lines = text.splitlines()
    index = 0
    while index < len(lines):
        start = index + 1
        logical = lines[index]
        while logical.rstrip().endswith("\\") and index + 1 < len(lines):
            logical = logical.rstrip()[:-1] + " " + lines[index + 1].lstrip()
            index += 1
        yield start, logical
        index += 1


def require_image(image, path, line, errors, images):
    image = image.strip("'\"")
    if image == "scratch":
        return
    images.append((str(path), line, image))
    if not IMAGE_RE.fullmatch(image):
        errors.append(f"{path}:{line}: image is not pinned by sha256 digest: {image}")


def scan_uses(path, text, errors, counts):
    for line_number, line in enumerate(text.splitlines(), 1):
        match = USES_RE.match(line)
        if not match:
            continue
        reference, comment = match.groups()
        if reference.startswith("./"):
            continue
        counts["external"] += 1
        if reference.startswith("esp-rs/xtensa-toolchain@"):
            errors.append(
                f"{path}:{line_number}: esp-rs/xtensa-toolchain downloads mutable latest binaries"
            )
        if re.fullmatch(rf"[^@\s]+@{SHA}", reference) and comment:
            counts["pinned"] += 1
        else:
            errors.append(
                f"{path}:{line_number}: external action must use a 40-character SHA and trailing version comment"
            )
        continue
    for line_number, line in enumerate(text.splitlines(), 1):
        for match in INLINE_USES_RE.finditer(line):
            reference = match.group(1).strip("'\"")
            if reference.startswith("./"):
                continue
            counts["external"] += 1
            errors.append(
                f"{path}:{line_number}: external actions must use block syntax with a pinned SHA and version comment"
            )


def scan_images(path, text, errors, images):
    lines = text.splitlines()
    if is_dockerfile(path):
        for line_number, line in enumerate(lines, 1):
            match = re.match(r"^\s*FROM\s+([^\s]+)", line, re.IGNORECASE)
            if match:
                require_image(match.group(1), path, line_number, errors, images)
    if is_workflow(path):
        for line_number, line in enumerate(lines, 1):
            match = re.match(r"^\s*container:\s*([^\s#]+)", line)
            if match:
                require_image(match.group(1), path, line_number, errors, images)
        for line_number, line in enumerate(lines, 1):
            if re.search(r"\bdocker\s+run\b", line):
                block = "\n".join(lines[line_number - 1 : line_number + 15])
                match = re.search(rf"([^\s'\"]+@{DIGEST})\s+copybara\b", block)
                if not match:
                    errors.append(f"{path}:{line_number}: docker run image is not digest-pinned")
                else:
                    require_image(match.group(1), path, line_number, errors, images)
    if is_cloudbuild(path):
        substitutions = {}
        for line in lines:
            match = re.match(r"^\s{2}(_[A-Z0-9_]+):\s*([^\s#]+)", line)
            if match:
                substitutions[match.group(1)] = match.group(2).strip("'\"")
        for line_number, line in enumerate(lines, 1):
            match = re.match(r"^\s*- name:\s*([^\s#]+)", line)
            if not match:
                continue
            image = match.group(1).strip("'\"")
            variable = re.fullmatch(r"\$\{(_[A-Z0-9_]+)\}", image)
            if variable:
                image = substitutions.get(variable.group(1), "")
            require_image(image, path, line_number, errors, images)


def scan_downloads(path, text, errors):
    lines = text.splitlines()
    for line_number, line in logical_lines(text):
        if line.lstrip().startswith("#"):
            continue
        if ("http_code" in line and "--max-time" in line) or "--head" in line or " -I" in line:
            continue
        if re.search(r"\b(?:curl|wget)\b.*\|\s*(?:sh|bash|python|node|tar|unzip|gzip)\b", line):
            errors.append(f"{path}:{line_number}: remote content is executed or extracted directly without verification")
            continue
        download = (
            (re.search(r"\b(?:curl|wget)\b", line) and re.search(r"(?:\s-o\s|--output|\.tar\.gz|\.zip|\.tgz|\$url|\burl\b|archive)", line))
            or "gh release download" in line
            or "urlretrieve(" in line
        )
        if not download:
            continue
        index = line_number - 1
        window = "\n".join(lines[max(0, index - 4) : index + 13])
        checksum = re.search(r"sha256sum|shasum\s+-a\s+256|hashlib\.sha256", window)
        expectation = re.search(r"\$\{?[A-Z0-9_]*SHA256\}?|[0-9a-f]{64}", window)
        if not checksum or not expectation:
            errors.append(f"{path}:{line_number}: downloaded executable lacks independent SHA-256 verification")


def scan_installs(path, text, errors):
    lines = active_lines(text)
    joined = "\n".join(lines)
    for line_number, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        code = line.split(" #", 1)[0]
        if re.search(r"(?:@|\b)(?:latest|stable)(?:\b|$)", code) and re.search(
            r"(?:npm|pipx?|cargo|rustup|brew).*\binstall\b|(?:node|python|ruby|go|java|xcode|otp|elixir|rebar3|gradle)-version\s*:|toolchain\s*:",
            code,
        ):
            errors.append(f"{path}:{line_number}: latest/stable executable input is forbidden")
        if re.search(r"\bbrew\s+install\b", code):
            errors.append(f"{path}:{line_number}: Homebrew install is not immutable")
        if re.search(r"\bpipx\s+install\b", code):
            errors.append(f"{path}:{line_number}: pipx install cannot enforce the repository hash lock")
        if re.search(r"(?:\bpip|/pip\")\s+install\b", code) and not (
            "--require-hashes" in code
            and re.search(r"(?:^|\s)(?:-r|--requirement)(?:\s|=)", code)
        ):
            errors.append(f"{path}:{line_number}: pip install must use --require-hashes and a requirement file")
        if re.search(r"(?:\bpip|/pip\")\s+download\b", code) and not (
            "--require-hashes" in code
            and re.search(r"(?:^|\s)(?:-r|--requirement)(?:\s|=)", code)
        ):
            errors.append(f"{path}:{line_number}: pip download must use --require-hashes and a requirement file")
        if re.search(r"\bcargo\s+install\b", code):
            exact_variable = re.search(r"--version\s+[\"']?\$[A-Z_]+[\"']?", code) and re.search(
                r"^[ \t]*[A-Z_]+:\s*[\"']?[0-9]+\.[0-9]+\.[0-9]+", joined, re.MULTILINE
            )
            if "--locked" not in code or ("--version" not in code or not (re.search(r"--version\s+[\"']?[0-9]+\.[0-9]+\.[0-9]+", code) or exact_variable)):
                errors.append(f"{path}:{line_number}: cargo install must use --locked and an exact version")
        if re.search(r"\bnpm\s+install\b", code) and not re.search(r"@[0-9]+\.[0-9]+\.[0-9]+", code):
            errors.append(f"{path}:{line_number}: npm install must use an exact package version or npm ci")
        if "mix local.hex" in code and not re.search(r"local\.hex\s+[0-9]+\.[0-9]+\.[0-9]+", code):
            errors.append(f"{path}:{line_number}: mix local.hex must use an exact version")
        if "mix local.rebar" in code:
            errors.append(f"{path}:{line_number}: floating mix local.rebar is forbidden")

    version_keys = (
        "node-version",
        "python-version",
        "ruby-version",
        "go-version",
        "java-version",
        "xcode-version",
        "otp-version",
        "elixir-version",
        "rebar3-version",
        "crystal",
        "tofu_version",
        "gradle-version",
        "toolchain",
    )
    for line_number, line in enumerate(text.splitlines(), 1):
        match = re.match(r"^\s*(" + "|".join(re.escape(key) for key in version_keys) + r"):\s*[\"']?([^\"'#\s]+)", line)
        if not match:
            continue
        value = match.group(2)
        if not re.fullmatch(r"[0-9]+\.[0-9]+(?:\.[0-9]+)*(?:[-+][A-Za-z0-9._-]+)?", value):
            errors.append(f"{path}:{line_number}: {match.group(1)} is not an exact version: {value}")

    for line_number, line in logical_lines("\n".join(lines)):
        if "wasm-pack build" in line and "--mode no-install" not in line:
            errors.append(
                f"{path}:{line_number}: wasm-pack build can fetch secondary binaries; use --mode no-install"
            )
        if re.search(r"\bpio\s+run\b", line) and not re.search(
            r"(?:^|\s)(?:-c|--project-conf)(?:\s|=)", line
        ):
            errors.append(
                f"{path}:{line_number}: PlatformIO build must use a rendered offline project config"
            )
        for match in re.finditer(
            r"\bapt-get\s+install\s+(?:-\S+\s+)*(.*?)(?=\s*(?:&&|\|\||;)|$)",
            line,
        ):
            packages = [token for token in match.group(1).split() if not token.startswith("-")]
            floating = [token for token in packages if "=" not in token]
            if floating:
                errors.append(
                    f"{path}:{line_number}: apt-get install has floating packages: {floating}"
                )


def scan_gradle_wrapper(path, text, errors):
    if path.name != "gradle-wrapper.properties" or "distributionUrl=" not in text:
        return
    matches = re.findall(r"^distributionSha256Sum=([0-9a-f]{64})$", text, re.MULTILINE)
    if len(matches) != 1:
        errors.append(f"{path}: Gradle distribution must have exactly one SHA-256 checksum")


def platformio_values(text, key):
    values = []
    collecting = False
    for line_number, raw in enumerate(text.splitlines(), 1):
        line = raw.split(";", 1)[0].rstrip()
        match = re.match(rf"^\s*{re.escape(key)}\s*=\s*(.*?)\s*$", line)
        if match:
            collecting = True
            if match.group(1):
                values.append((line_number, match.group(1)))
            continue
        if collecting:
            if not line.strip():
                continue
            if raw[:1].isspace() and "=" not in line:
                values.append((line_number, line.strip()))
                continue
            collecting = False
    return values


def scan_platformio(path, text, errors, locked_references):
    if path.name != "platformio.ini":
        return
    platforms = platformio_values(text, "platform")
    if len(platforms) != 1:
        errors.append(f"{path}: PlatformIO config must declare exactly one platform")
    else:
        line, reference = platforms[0]
        if not PLATFORMIO_REF_RE.fullmatch(reference):
            errors.append(f"{path}:{line}: PlatformIO platform is not pinned exactly: {reference}")

    packages = platformio_values(text, "platform_packages")
    if not packages:
        errors.append(f"{path}: PlatformIO config must pin its platform_packages")
    for line, reference in packages:
        if not PLATFORMIO_REF_RE.fullmatch(reference):
            errors.append(f"{path}:{line}: PlatformIO package is not pinned exactly: {reference}")
    references = [reference for _, reference in platforms + packages]
    if len(references) != len(set(references)):
        errors.append(f"{path}: PlatformIO inputs contain duplicates")
    if locked_references is None:
        errors.append(f"{path}: PlatformIO checksum lock is absent")
    elif set(references) != locked_references:
        errors.append(f"{path}: PlatformIO inputs differ from the checksum lock")


def scan_platformio_lock(root, paths, errors):
    configs = [path for path in paths if path.name == "platformio.ini"]
    lock_path = root / "sdk/embedded/platformio-packages.lock.json"
    if not configs and not lock_path.exists():
        return None
    if not lock_path.is_file():
        errors.append("sdk/embedded/platformio-packages.lock.json: PlatformIO checksum lock is absent")
        return None
    try:
        data = json.loads(lock_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        errors.append(f"sdk/embedded/platformio-packages.lock.json: invalid lock: {error}")
        return None
    if set(data) != {"packages", "schema", "system"} or data.get("schema") != 1:
        errors.append("sdk/embedded/platformio-packages.lock.json: invalid schema")
        return None
    entries = data.get("packages")
    if not isinstance(entries, list) or not entries:
        errors.append("sdk/embedded/platformio-packages.lock.json: package list is empty")
        return None
    references = set()
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != {
            "filename", "kind", "metadata", "reference", "sha256", "url"
        }:
            errors.append("sdk/embedded/platformio-packages.lock.json: package fields are invalid")
            continue
        reference = entry["reference"]
        if not PLATFORMIO_REF_RE.fullmatch(reference):
            errors.append(f"sdk/embedded/platformio-packages.lock.json: invalid reference: {reference}")
        if not re.fullmatch(r"[0-9a-f]{64}", entry["sha256"]):
            errors.append(f"sdk/embedded/platformio-packages.lock.json: invalid digest: {reference}")
        parsed_url = re.fullmatch(
            r"https://(dl\.registry\.platformio\.org|usc1\.contabostorage\.com)/.+",
            entry["url"],
        )
        if not parsed_url:
            errors.append(f"sdk/embedded/platformio-packages.lock.json: invalid download URL: {reference}")
        if not entry["metadata"].startswith("https://api.registry.platformio.org/v3/packages/"):
            errors.append(f"sdk/embedded/platformio-packages.lock.json: invalid metadata URL: {reference}")
        if reference in references:
            errors.append(f"sdk/embedded/platformio-packages.lock.json: duplicate reference: {reference}")
        references.add(reference)
    return references


def workflow_jobs(text):
    jobs = {}
    current = None
    lines = text.splitlines()
    for line_number, line in enumerate(lines):
        match = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
        if not match:
            continue
        if current is not None:
            name, start = current
            jobs[name] = "\n".join(lines[start:line_number])
        current = (match.group(1), line_number + 1)
    if current is not None:
        name, start = current
        jobs[name] = "\n".join(lines[start:])
    return jobs


def scan_release_authority(path, text, errors):
    active_text = "\n".join(active_lines(text))
    if not is_workflow(path) or not PUBLISH_RE.search(active_text):
        return
    jobs = workflow_jobs(text)
    build_jobs = [(name, block) for name, block in jobs.items() if "release-artifact.py create" in block]
    publish_jobs = [
        (name, block)
        for name, block in jobs.items()
        if PUBLISH_RE.search("\n".join(active_lines(block)))
    ]
    if len(build_jobs) != 1:
        errors.append(f"{path}: publishing workflow must have exactly one manifest-producing build job")
    else:
        name, block = build_jobs[0]
        if "secrets." in block or "environment:" in block:
            errors.append(f"{path}: build job {name} has protected publication authority")
        if re.search(r"\b(?:id-token|attestations|packages|pages):\s*write", block):
            errors.append(f"{path}: build job {name} has write or OIDC authority")
        if PUBLISH_RE.search("\n".join(active_lines(block))):
            errors.append(f"{path}: build job {name} also publishes")
        if "actions/upload-artifact@" not in block:
            errors.append(f"{path}: build job {name} does not upload an immutable artifact")
    for name, block in publish_jobs:
        if "environment: release" not in block:
            errors.append(f"{path}: publish job {name} is not protected by the release environment")
        if not re.search(r"needs:.*build", block):
            errors.append(f"{path}: publish job {name} does not depend on build")
        if "actions/download-artifact@" not in block or "release-artifact.py verify" not in block:
            errors.append(f"{path}: publish job {name} does not verify the immutable build artifact")
        if BUILD_RE.search("\n".join(active_lines(block))):
            errors.append(f"{path}: publish job {name} also builds or tests")


def scan_terraform(path, text, errors, images):
    for line_number, line in enumerate(text.splitlines(), 1):
        code = line.split("#", 1)[0]
        if re.search(r":[Ll][Aa][Tt][Ee][Ss][Tt](?:[^A-Za-z0-9_.-]|$)", code):
            errors.append(f"{path}:{line_number}: Terraform image references must not use :latest")
    image_locals = {}
    for line_number, line in enumerate(text.splitlines(), 1):
        match = re.match(r'^\s*([A-Za-z0-9_]*_image)\s*=\s*"([^"\s]+)"', line)
        if not match:
            continue
        name, image = match.groups()
        image_locals[name] = (line_number, image)
        require_image(image, path, line_number, errors, images)
    for line_number, line in enumerate(text.splitlines(), 1):
        match = re.match(r"^\s*name\s*=\s*local\.([A-Za-z0-9_]*_image)\s*$", line)
        if match and match.group(1) not in image_locals:
            errors.append(f"{path}:{line_number}: Cloud Build step image local is not a pinned literal in this file")


def check(root):
    errors = []
    images = []
    counts = {"external": 0, "pinned": 0}
    paths = repository_files(root)
    locked_platformio = scan_platformio_lock(root, paths, errors)
    for path in paths:
        relative = path.relative_to(root)
        if path.name.endswith(".test.sh"):
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        if is_workflow(relative):
            scan_uses(relative, text, errors, counts)
            scan_release_authority(relative, text, errors)
        if is_workflow(relative) or is_cloudbuild(relative) or is_dockerfile(relative):
            scan_images(relative, text, errors, images)
            scan_installs(relative, text, errors)
            scan_downloads(relative, text, errors)
        elif relative.suffix == ".sh":
            scan_installs(relative, text, errors)
            scan_downloads(relative, text, errors)
        elif relative.as_posix() == "assets/wordmark/make_preview.py":
            scan_downloads(relative, text, errors)
        if is_terraform(relative):
            scan_terraform(relative, text, errors, images)
        scan_gradle_wrapper(relative, text, errors)
        scan_platformio(relative, text, errors, locked_platformio)
    return errors, counts, images


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=".")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    root = Path(args.root).resolve()
    errors, counts, images = check(root)
    report = {
        "external_uses": counts["external"],
        "pinned_uses": counts["pinned"],
        "images": [image for _, _, image in images],
        "errors": errors,
    }
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        for error in errors:
            print(f"ERROR: {error}")
        print(f"external uses: {counts['external']}; pinned to full SHA: {counts['pinned']}")
        for path, line, image in images:
            print(f"image: {image} ({path}:{line})")
    if errors:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
