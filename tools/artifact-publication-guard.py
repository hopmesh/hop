#!/usr/bin/env python3
"""Every workflow that publishes a BUILD ARTIFACT outside this repository must prove canonical CI.

Scope, stated precisely so a green run cannot be over-read: this guard reads .github/workflows/**.yml
and looks for the release-publishing verbs that put a built file somewhere the public can download it
(a GitHub Release, on any repo). It does NOT audit source mirroring (sync-components.yml replays
commits, not builds), tag creation (release-tags.yml, whose tags fire the mirrors' own release
workflows), registry publishes that live in the mirror repos, or infrastructure deploys.

The invariant it enforces on the workflows in scope: the artifact may only be built and published from
a commit whose canonical CI workflow completed successfully, asserted with the SAME authority the rest
of the release chain uses, `tools/native-artifacts.py authorize-ci --source-sha`, in its own job that
every artifact-producing and artifact-publishing job depends on. Two implementations of "did CI pass"
is how one of them drifts, so a workflow re-deriving the check itself fails this guard.

Background: libhop-esp-release.yml published static libraries plus sdk/hop.h to the PUBLIC
hopmesh/libhop repo, since RETIRED along with the rest of the mirror fleet, while checking only the
repository, ref, ref-protected flag, sha shape and version shape. Nothing tied the build to a passing
test suite, header-drift gate, or wire-version guard. That
workflow has since been DELETED (its credentials were never provisionable and native-artifacts.yml
builds a superset of its targets under signature), so this repo currently has NO workflow in scope. The
rule is still enforced on every run, by the fixtures in tools/artifact-publication-guard.test.sh; what
a green run here means is stated exactly, in the count it prints, so "0 in scope" can never be read as
"the publication paths were checked and are sound".
"""

import re
import sys
from pathlib import Path


AUTHORIZE_COMMAND = "tools/native-artifacts.py authorize-ci --source-sha"
# The verbs that put a built file on a public download surface. Additions here widen the guard.
PUBLICATION_MARKERS = (
    "gh release create",
    "gh release upload",
    "softprops/action-gh-release",
    "actions/upload-release-asset",
)
# Jobs that neither build nor publish the artifact and therefore need no CI authorization of their own.
EXEMPT_JOB_SUFFIXES = ("authorize-ci",)


class PublicationAuthorityError(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise PublicationAuthorityError(message)


def jobs(text):
    """Split a workflow's `jobs:` mapping into (id, body) pairs, by two-space indentation."""
    match = re.search(r"(?ms)^jobs:\n(.*)\Z", text)
    if match is None:
        return []
    body = match.group(1)
    found = []
    for job in re.finditer(r"(?ms)^  ([A-Za-z0-9_-]+):\n(.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)", body):
        found.append((job.group(1), job.group(2)))
    return found


def publishes(text):
    return any(marker in text for marker in PUBLICATION_MARKERS)


def needs_of(body):
    match = re.search(r"^\s*needs:\s*(.+)$", body, re.MULTILINE)
    if match is None:
        return set()
    value = match.group(1).strip()
    if value.startswith("["):
        value = value[1:-1]
    return {part.strip() for part in value.split(",") if part.strip()}


def transitive_needs(job_id, by_id):
    seen, pending = set(), list(needs_of(by_id.get(job_id, "")))
    while pending:
        current = pending.pop()
        if current in seen:
            continue
        seen.add(current)
        pending.extend(needs_of(by_id.get(current, "")))
    return seen


def check_workflow(name, text):
    """Return True when this workflow is in scope and satisfies the invariant."""
    if not publishes(text):
        return False
    found = jobs(text)
    by_id = dict(found)
    authorizers = {job_id for job_id, body in found if AUTHORIZE_COMMAND in body}
    require(
        authorizers,
        f"{name} publishes a build artifact but never runs `{AUTHORIZE_COMMAND}`; "
        "a public artifact must prove the canonical CI gate passed for its exact source sha",
    )
    for job_id, body in found:
        if job_id in authorizers or job_id.endswith(EXEMPT_JOB_SUFFIXES):
            continue
        reachable = transitive_needs(job_id, by_id)
        require(
            authorizers & reachable,
            f"{name}: job `{job_id}` does not depend on the CI authorization job "
            f"({', '.join(sorted(authorizers))}), so it runs before CI success is proven",
        )
    for job_id, body in found:
        if job_id in authorizers:
            continue
        require(
            "actions/workflows/ci.yml/runs" not in body and "workflow_runs" not in body,
            f"{name}: job `{job_id}` re-implements the CI-success check; "
            f"use `{AUTHORIZE_COMMAND}` so there is one authority, not two",
        )
    return True


def check(root):
    workflows = sorted((Path(root) / ".github/workflows").glob("*.yml"))
    require(workflows, "no workflows found")
    in_scope = [w.name for w in workflows if check_workflow(w.name, w.read_text(encoding="utf-8"))]
    if in_scope:
        print(f"artifact publication authority OK ({len(in_scope)} in scope): " + ", ".join(in_scope))
    else:
        # Say what a pass means here. It does NOT mean the publication paths were audited; it means
        # this repo has none. The rule that any new one must prove canonical CI is exercised by the
        # self-test fixtures on every CI run, which is what keeps this from being an empty statement.
        print(
            f"artifact publication authority OK (0 in scope): none of the {len(workflows)} workflows "
            "in .github/workflows publishes a build artifact outside this repository, so this run "
            "asserts nothing about any live publication path; the rule is exercised by "
            "tools/artifact-publication-guard.test.sh"
        )
    return in_scope


def main():
    root = Path(__file__).resolve().parent.parent
    try:
        check(root)
    except PublicationAuthorityError as error:
        print(f"::error::artifact publication authority: {error}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
