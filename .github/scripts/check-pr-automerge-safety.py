#!/usr/bin/env python3
"""Inspect PR title and body for review-intent, WIP, RFC, hold, and do-not-merge markers (PROC-002).

Normalizes text (NFKC, casefold, strip zero-width and non-ASCII whitespace, map hyphens/underscores/dots
to spaces) and matches review markers before allowing auto-merge.
"""
import os
import re
import sys
import unicodedata


ZERO_WIDTH = r"[\u200b-\u200f\u2060\ufeff\xad]"


def _finish(norm: str) -> str:
    # Casefold, map hyphens, underscores, dots, slashes and common punctuation between words to
    # spaces, then collapse whitespace.
    norm = norm.casefold()
    norm = re.sub(r"[-_./:;,!?()\[\]{}'\"]+", " ", norm)
    return " " + " ".join(norm.split()) + " "


def normalize_forms(text: str) -> list[str]:
    """Every normalized shape a marker can hide in.

    Zero-width characters are the one class that cannot be normalized one way: an attacker can put
    them BETWEEN words (`do<zw>not<zw>merge`, where deleting them fuses the words and hides the
    boundary) or INSIDE a word (`w<zw>ip`, where treating them as spaces splits the word). So both
    forms are produced and a marker matching either one counts.
    """
    if not text:
        return []
    norm = unicodedata.normalize("NFKC", text)
    return [_finish(re.sub(ZERO_WIDTH, " ", norm)), _finish(re.sub(ZERO_WIDTH, "", norm))]


def normalize_text(text: str) -> str:
    forms = normalize_forms(text)
    return forms[0] if forms else ""


def check_review_intent(title: str, body: str) -> list[str]:
    # Match phrases including:
    # do not merge, dont merge, dnm, wip, rfc (with optional digits), research,
    # hold, review only, needs review, please review, for review, under review,
    # not ready, draft, blocked, experiment
    patterns = [
        (r"\bdo\s+not\s+merge\b", "do not merge"),
        (r"\bdont\s+merge\b", "dont merge"),
        (r"\bdnm\b", "dnm"),
        (r"\bw\s*i\s*p\b", "wip"),
        (r"\brfc\s*\d*\b", "rfc"),
        (r"\bresearch\b", "research"),
        (r"\bhold\b", "hold"),
        (r"\breview\s+only\b", "review only"),
        (r"\bneeds\s+review\b", "needs review"),
        (r"\bplease\s+review\b", "please review"),
        (r"\bfor\s+review\b", "for review"),
        (r"\bunder\s+review\b", "under review"),
        (r"\bnot\s+ready\b", "not ready"),
        (r"\bdraft\b", "draft"),
        (r"\bblocked\b", "blocked"),
        (r"\bexperiment\b", "experiment"),
    ]

    title_forms = normalize_forms(title)
    body_forms = normalize_forms(body)

    found = []
    for pat, label in patterns:
        if any(re.search(pat, form) for form in title_forms):
            found.append(f"title matched '{label}'")
        elif any(re.search(pat, form) for form in body_forms):
            found.append(f"body matched '{label}'")
    return found


def main() -> int:
    title = os.environ.get("TITLE", "")
    body = os.environ.get("BODY", "")

    reasons = check_review_intent(title, body)
    output_path = os.environ.get("GITHUB_OUTPUT")

    if reasons:
        msg = f"Auto-merge refused: {'; '.join(reasons)}. PR requires human review and must not auto-merge."
        print(f"::notice title=Auto-merge refused::{msg}")
        if output_path:
            with open(output_path, "a", encoding="utf-8") as f:
                f.write("arm_automerge=false\n")
        return 0

    if output_path:
        with open(output_path, "a", encoding="utf-8") as f:
            f.write("arm_automerge=true\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
