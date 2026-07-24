#!/usr/bin/env python3
"""Create the `vX.Y.Z` release tag on each public mirror that is not tagged at its version yet.

Creating the tag is what publishes: it fires the mirror's own release.yml, which builds and pushes to
the registry through OIDC trusted publishing. So this errs toward doing nothing. A component is tagged
only when all of the following hold, and is otherwise skipped (never forced, never retagged):

  1. the mirror has no `v<version>` tag already, so an ordinary merge with no version bump tags nothing
     and a re-run is a no-op;
  2. the mirror's main actually declares that version. The export is what carries a bump to the
     mirror, and it may not have landed yet; tagging early would point the tag at code whose manifest
     says something else, and every manifest-bearing mirror's release.yml asserts
     `tag == manifest version` and would fail the publish. Skipping just defers to the next run.

Components whose ecosystem has no in-repo version (SwiftPM, Go, and the artifact-publishing Android
and embedded SDKs, reported by plan.py as the workspace anchor) have nothing on the mirror to compare,
and their release workflows assert no manifest version, so rule 2 does not apply to them.
"""

import json
import os
import re
import sys
import tomllib
import urllib.error
import urllib.request


API = "https://api.github.com"
OWNER = "hopmesh"
ANCHOR_SOURCE = "workspace anchor"


class TagError(RuntimeError):
    pass


def request(path, token, method="GET", payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(f"{API}{path}", data=data, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            body = response.read().decode()
            return json.loads(body) if body else {}, response.status
    except urllib.error.HTTPError as error:
        return None, error.code


def version_from_text(filename, text):
    """Extract a declared version from a manifest's CONTENT, matching plan.py's per-ecosystem rules."""
    name = filename.rsplit("/", 1)[-1]
    if name == "package.json":
        return json.loads(text).get("version")
    if name == "pyproject.toml":
        return tomllib.loads(text).get("project", {}).get("version")
    if name == "Cargo.toml":
        version = tomllib.loads(text).get("package", {}).get("version")
        # An inherited version cannot be read from the mirror (it has no workspace root), so treat it
        # as unverifiable rather than guessing.
        return None if isinstance(version, dict) else version
    if name == "shard.yml":
        match = re.search(r"^version:\s*['\"]?([0-9][^'\"\s]*)", text, re.MULTILINE)
        return match.group(1) if match else None
    if name == "mix.exs":
        match = re.search(r"version:\s*\"([0-9][^\"]*)\"", text)
        return match.group(1) if match else None
    if name.endswith(".gemspec"):
        match = re.search(r"\.version\s*=\s*['\"]([0-9][^'\"]*)['\"]", text)
        return match.group(1) if match else None
    if name == "version.rb":
        match = re.search(r"VERSION\s*=\s*['\"]([0-9][^'\"]*)['\"]", text)
        return match.group(1) if match else None
    return None


def decide(entry, tag_exists, mirror_version, mirror_has_any_tag=True, allow_first_tag=False):
    """Pure policy: tag, or skip with a reason. mirror_version is None when unread/unverifiable."""
    version = entry["version"]
    if tag_exists:
        return False, f"already tagged v{version}"
    # A mirror with NO tags at all is not a routine version bump, it is that component's first ever
    # release, and every untagged component qualifies at once. Landing this workflow tagged eleven
    # mirrors in one go and fired eleven release workflows; the registries were spared only by a
    # separate approval gate. So a first tag is deliberate-only: dispatch with first_tag=yes. An
    # ordinary bump on an already-tagged mirror stays automatic.
    if not mirror_has_any_tag and not allow_first_tag:
        return False, (
            f"v{version} would be this mirror's FIRST tag; "
            "dispatch Release tags with first_tag=yes to allow it"
        )
    if entry["source"] == ANCHOR_SOURCE:
        return True, f"tagging v{version} (no in-repo version to verify)"
    if mirror_version is None:
        return False, f"mirror manifest {entry['source']} unreadable, deferring"
    if mirror_version != version:
        return False, f"mirror still at {mirror_version}, waiting for the export of {version}"
    return True, f"tagging v{version}"


def process(entry, token, allow_first_tag=False):
    repo = entry["component"]
    version = entry["version"]
    tag = f"v{version}"

    ref, status = request(f"/repos/{OWNER}/{repo}/git/ref/tags/{tag}", token)
    if status not in (200, 404):
        raise TagError(f"{repo}: unexpected status {status} reading tag {tag}")
    tag_exists = status == 200

    # Does this mirror have ANY tag? Distinguishes a routine bump from a first-ever release.
    mirror_has_any_tag = tag_exists
    if not tag_exists:
        tags, status = request(f"/repos/{OWNER}/{repo}/tags?per_page=1", token)
        if status != 200:
            raise TagError(f"{repo}: cannot list tags ({status})")
        mirror_has_any_tag = bool(tags)

    mirror_version = None
    if not tag_exists and entry["source"] != ANCHOR_SOURCE:
        contents, status = request(
            f"/repos/{OWNER}/{repo}/contents/{entry['source']}?ref=main", token
        )
        if status == 200 and contents.get("content"):
            import base64

            text = base64.b64decode(contents["content"]).decode("utf-8", "replace")
            mirror_version = version_from_text(entry["source"], text)

    should_tag, reason = decide(
        entry, tag_exists, mirror_version, mirror_has_any_tag, allow_first_tag
    )
    print(f"{repo}: {reason}")
    if not should_tag:
        return False

    head, status = request(f"/repos/{OWNER}/{repo}/git/ref/heads/main", token)
    if status != 200:
        raise TagError(f"{repo}: cannot read main ({status})")
    sha = head["object"]["sha"]

    _, status = request(
        f"/repos/{OWNER}/{repo}/git/refs",
        token,
        method="POST",
        payload={"ref": f"refs/tags/{tag}", "sha": sha},
    )
    # 422 means the ref appeared between the read and the write; that is still "already tagged".
    if status == 422:
        print(f"{repo}: {tag} already created concurrently")
        return False
    if status != 201:
        raise TagError(f"{repo}: creating {tag} failed ({status})")
    print(f"{repo}: created {tag} at {sha[:12]}")
    return True


def main():
    token = os.environ.get("GH_TOKEN")
    if not token:
        raise TagError("GH_TOKEN is required")
    entries = json.loads(os.environ.get("PLAN") or "[]")
    if not entries:
        raise TagError("PLAN is empty")
    # Opt-in for a mirror's first ever tag; only a deliberate dispatch sets this.
    allow_first_tag = os.environ.get("ALLOW_FIRST_TAG", "").strip().lower() == "yes"
    if allow_first_tag:
        print("first_tag=yes: mirrors with no tags at all are eligible in this run")
    tagged = 0
    for entry in entries:
        tagged += 1 if process(entry, token, allow_first_tag) else 0
    print(f"release tags created: {tagged}")


if __name__ == "__main__":
    try:
        main()
    except (TagError, OSError, ValueError, KeyError) as error:
        raise SystemExit(f"release tagging failed: {error}") from error
