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
        document = tomllib.loads(text)
        version = document.get("package", {}).get("version")
        if not isinstance(version, dict):
            return version
        # `version.workspace = true` inherits from a workspace root. On the MIRROR that root is the
        # [workspace.package] preamble copy.bara.sky injects on export (WORKSPACE_PREAMBLE), which
        # carries a literal version that tools/version-align-guard.sh keeps equal to the anchor. So
        # the inherited version IS resolvable here; resolve it from the same document. Only a
        # manifest that inherits with no workspace root in it is genuinely unverifiable.
        if not version.get("workspace"):
            return None
        return document.get("workspace", {}).get("package", {}).get("version")
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


GIT_ORIGIN_REV = re.compile(r"^GitOrigin-RevId: ([0-9a-f]{40})$", re.MULTILINE)


def source_revision(repo, token):
    """The monorepo commit a mirror's main was exported from, via copybara's GitOrigin-RevId."""
    head, status = request(f"/repos/{OWNER}/{repo}/git/ref/heads/main", token)
    if status != 200:
        return None
    commit, status = request(f"/repos/{OWNER}/{repo}/git/commits/{head['object']['sha']}", token)
    if status != 200:
        return None
    found = GIT_ORIGIN_REV.findall(commit.get("message") or "")
    # Exactly one, or we cannot say which source commit this mirror state came from.
    return found[0] if len(found) == 1 else None


def source_is_releasable(source_sha, token):
    """Is the canonical commit ready to be released from? (reason, ok)

    Tagging is what starts a publish, and the mirror's release job will REFUSE a source commit whose
    CI gate or native-artifacts run has not finished successfully. The export completes in seconds
    while those take roughly twenty minutes, so tagging on export completion reliably created tags
    that could not publish yet. Worse, the tagger never retags, so each of those tags then sat behind
    mirror main permanently and was skipped forever. Every release in this repo's first real run hit
    that race, repeatedly. So check the same two things the release job checks, and simply wait.
    """
    checks, status = request(f"/repos/{OWNER}/monorepo/commits/{source_sha}/check-runs", token)
    if status != 200:
        return False, f"cannot read canonical checks ({status})"
    gate = [run for run in (checks.get("check_runs") or []) if run.get("name") == "CI gate"]
    if not gate:
        return False, "canonical CI gate has not reported yet"
    latest = sorted(gate, key=lambda run: run.get("started_at") or "")[-1]
    if latest.get("status") != "completed":
        return False, "canonical CI gate is still running"
    if latest.get("conclusion") != "success":
        return False, f"canonical CI gate concluded {latest.get('conclusion')}"

    runs, status = request(
        f"/repos/{OWNER}/monorepo/actions/workflows/native-artifacts.yml/runs"
        f"?head_sha={source_sha}&per_page=10",
        token,
    )
    if status != 200:
        return False, f"cannot read native-artifacts runs ({status})"
    matching = [run for run in (runs.get("workflow_runs") or []) if run.get("head_sha") == source_sha]
    if not matching:
        return False, "native artifacts have not started for this source"
    if not any(run.get("conclusion") == "success" for run in matching):
        states = ", ".join(sorted({f"{r.get('status')}/{r.get('conclusion') or ''}" for r in matching}))
        return False, f"native artifacts not successful ({states})"
    return True, "canonical CI gate and native artifacts are green"


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
        # Reachable ONLY when the mirror does not carry the manifest yet (the export has not landed).
        # A manifest that IS present but yields no version is raised as an error by process(), because
        # that state never clears on its own and a silent skip would defer the release forever.
        return False, f"mirror does not carry {entry['source']} yet, deferring until the export lands"
    if mirror_version != version:
        return False, f"mirror still at {mirror_version}, waiting for the export of {version}"
    return True, f"tagging v{version}"


def process(entry, token, allow_first_tag=False, source_token=None):
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
        if status not in (200, 404):
            raise TagError(f"{repo}: unexpected status {status} reading {entry['source']}")
        if status == 200 and contents.get("content"):
            import base64

            text = base64.b64decode(contents["content"]).decode("utf-8", "replace")
            mirror_version = version_from_text(entry["source"], text)
            # The manifest is THERE and still yields nothing. That is not a transient wait for the
            # export, it is a state that repeats forever and silently never releases the component,
            # so it is an error. See release.test.sh, which pins the real exported manifests.
            if mirror_version is None:
                raise TagError(
                    f"{repo}: mirror carries {entry['source']} but no version could be read from it; "
                    "the export must produce a manifest whose declared version is resolvable"
                )

    should_tag, reason = decide(
        entry, tag_exists, mirror_version, mirror_has_any_tag, allow_first_tag
    )
    print(f"{repo}: {reason}")
    if not should_tag:
        return False

    # Everything above says this component SHOULD be tagged. The last question is whether the canonical
    # commit behind it can actually be released from yet; a tag created before that is a tag that can
    # never publish. Waiting costs one skipped run, since release-tags also fires when Native artifacts
    # completes, so the deferred component is picked up as soon as it is genuinely ready.
    if source_token:
        source_sha = source_revision(repo, token)
        if not source_sha:
            print(f"{repo}: cannot resolve the canonical source commit, deferring")
            return False
        ready, why = source_is_releasable(source_sha, source_token)
        if not ready:
            print(f"{repo}: deferring, {why} ({source_sha[:12]})")
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
    # Reads the CANONICAL repo (its CI gate + native-artifacts). Separate from the mirror App token,
    # which is deliberately scoped to the mirrors and cannot see the monorepo.
    source_token = os.environ.get("SOURCE_TOKEN") or None
    if allow_first_tag:
        print("first_tag=yes: mirrors with no tags at all are eligible in this run")
    tagged = 0
    for entry in entries:
        tagged += 1 if process(entry, token, allow_first_tag, source_token) else 0
    print(f"release tags created: {tagged}")


if __name__ == "__main__":
    try:
        main()
    except (TagError, OSError, ValueError, KeyError) as error:
        raise SystemExit(f"release tagging failed: {error}") from error
