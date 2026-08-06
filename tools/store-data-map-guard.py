#!/usr/bin/env python3
"""store-data-map-guard.py (SVC-004): keep DESIGN.md's durable-store data map honest.

Section 33 is the engineering-compliance map: what personal data the backbone persists, where it
lives, and which identifier classes land in each durable surface. It said "Three things land there"
and named sealed bundles, the presence index, and delivery ACKs, while `hop-store-firestore` was also
writing `relays/{node}/kv` (one document per peer the relay holds a forward-secret session with, keyed
by that peer's public key), the `mailboxes` spool, the critical-operation journal, the liveness
registry, and the tenant registry. A compliance artifact narrower than the code is worse than none:
every reader downstream of it, including the audit that found this, treats it as exhaustive.

Prose drifts. This guard makes the drift fail the build: every Firestore collection the store client
addresses must be named in section 33. It is deliberately dumb about the writing and strict about the
naming, so adding a collection forces one line in the map in the same commit.

Usage:  python3 tools/store-data-map-guard.py
Env:    STORE_MAP_SOURCE  override the store source file (self-test)
        STORE_MAP_DESIGN  override the design document (self-test)
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.environ.get(
    "STORE_MAP_SOURCE", os.path.join(ROOT, "core/stores/hop-store-firestore/src/lib.rs")
)
DESIGN = os.environ.get("STORE_MAP_DESIGN", os.path.join(ROOT, "DESIGN.md"))

# A Firestore REST path: `.../documents/<collection>/<doc>/<collection>/<doc>...`. Collections sit at
# EVEN offsets after `documents/`, documents at odd ones, so the odd segments (`{node}`, a test's
# `NODE`, a base58 id) are skipped without needing to know what they are.
PATH = re.compile(r"documents/([A-Za-z0-9_{}./:?=&-]*)")

# Segments that are path syntax rather than a collection name.
NOT_A_COLLECTION = {"", "."}


def collections(source_text):
    found = set()
    for raw in PATH.findall(source_text):
        # Trim a query string (`relays?showMissing=true`) and a REST verb (`{node}:runQuery`).
        segments = raw.split("?")[0].split("/")
        for index, segment in enumerate(segments):
            if index % 2 or "{" in segment or ":" in segment:
                continue
            if segment in NOT_A_COLLECTION:
                continue
            found.add(segment)
    return found


def named_in(section_text):
    """Collection names the section names as PATHS, i.e. inside a backticked code span.

    Prose-substring matching would pass `control` on the word "controls", so only code spans count:
    the inventory has to carry the real path (`relays/{node}/kv`), which is also what a reader needs.
    """
    spans = re.findall(r"`([^`]+)`", section_text)
    names = set()
    for span in spans:
        for token in re.split(r"[^A-Za-z0-9_-]+", span):
            if token:
                names.add(token)
    return names


def section_33(design_text):
    lines = design_text.splitlines()
    start = None
    for index, line in enumerate(lines):
        if line.startswith("## 33."):
            start = index
        elif start is not None and line.startswith("## 34."):
            return "\n".join(lines[start:index])
    if start is not None:
        return "\n".join(lines[start:])
    return ""


def main():
    try:
        source_text = open(SOURCE, encoding="utf-8").read()
        design_text = open(DESIGN, encoding="utf-8").read()
    except OSError as error:
        print(f"store-data-map-guard: cannot read input: {error}", file=sys.stderr)
        return 1

    found = collections(source_text)
    if not found:
        # Fail closed: an extraction that finds nothing would otherwise pass every tree vacuously.
        print(
            f"store-data-map-guard: no Firestore collections found in {SOURCE}; "
            "the extraction is broken, not the tree",
            file=sys.stderr,
        )
        return 1

    section = section_33(design_text)
    if not section:
        print(
            "store-data-map-guard: DESIGN.md has no section 33 (the durable-store data map)",
            file=sys.stderr,
        )
        return 1

    named = named_in(section)
    missing = sorted(name for name in found if name not in named)
    if missing:
        print(
            "store-data-map-guard: DESIGN.md section 33 does not name every durable collection the "
            "store writes. Missing: " + ", ".join(missing),
            file=sys.stderr,
        )
        print(
            "  Add each one to the inventory WITH the identifier classes it holds. The map is a "
            "compliance artifact; a collection absent from it is an undisclosed durable surface.",
            file=sys.stderr,
        )
        return 1

    print(
        "store-data-map-guard: OK, section 33 names all "
        f"{len(found)} durable collections ({', '.join(sorted(found))})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
