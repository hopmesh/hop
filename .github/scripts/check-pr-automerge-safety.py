#!/usr/bin/env python3
"""Inspect PR title and body for review-intent, WIP, RFC, hold, and do-not-merge markers (PROC-002).

Normalizes text (NFKC, casefold, strip zero-width and non-ASCII whitespace, map hyphens/underscores/dots
to spaces) and matches review markers before allowing auto-merge.
"""
import os
import re
import sys
import unicodedata


def normalize_text(text: str) -> str:
    if not text:
        return ""
    # 1. NFKC normalization
    norm = unicodedata.normalize("NFKC", text)
    # 2. Strip zero-width and invisible characters
    norm = re.sub(r"[\u200b-\u200f\u2060\ufeff\xad]", "", norm)
    # 3. Casefold
    norm = norm.casefold()
    # 4. Map hyphens, underscores, dots, slashes, and common punctuation between words to spaces
    norm = re.sub(r"[-_./:;,!?()\[\]{}'\"]+", " ", norm)
    # 5. Normalize whitespace
    return " " + " ".join(norm.split()) + " "


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

    norm_title = normalize_text(title)
    norm_body = normalize_text(body)

    found = []
    for pat, label in patterns:
        if re.search(pat, norm_title):
            found.append(f"title matched '{label}'")
        elif re.search(pat, norm_body):
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
