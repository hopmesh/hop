#!/usr/bin/env python3
"""Inspect PR title, body, commits, and changed files for auto-merge safety (PROC-002, INFRA-018, PROC-012).

Normalizes text (NFKC, homoglyph mapping, strip Unicode Cf format and bidi characters,
collapse whitespace) and matches review markers before allowing auto-merge.
Enforces that modifications to workflows, export tooling, and security-sensitive paths
require an explicit approved PR review.
Refuses PRs that rely on stale approval dates or blanket verbal approvals.
"""
import datetime
import json
import os
import re
import subprocess
import sys
import unicodedata


# Cyrillic and Greek homoglyphs mapped to ASCII equivalents
CYRILLIC_GREEK_HOMOGLYPHS = {
    # Cyrillic small
    "\u0430": "a", "\u0435": "e", "\u0451": "e", "\u043e": "o", "\u0440": "p",
    "\u0441": "c", "\u0443": "y", "\u0445": "x", "\u0455": "s", "\u0456": "i",
    "\u0458": "j", "\u04bb": "h", "\u043c": "m", "\u0442": "t", "\u0432": "v",
    "\u043a": "k", "\u0448": "w", "\u0449": "w",
    # Cyrillic capital
    "\u0410": "A", "\u0415": "E", "\u041e": "O", "\u0420": "P", "\u0421": "C",
    "\u0423": "Y", "\u0425": "X", "\u0405": "S", "\u0406": "I", "\u0408": "J",
    "\u04ba": "H", "\u041c": "M", "\u0422": "T", "\u0412": "V", "\u041a": "K",
    # Greek small
    "\u03b1": "a", "\u03b5": "e", "\u03b9": "i", "\u03ba": "k", "\u03bf": "o",
    "\u03c1": "p", "\u03c4": "t", "\u03c5": "y", "\u03c7": "x", "\u03bd": "v",
    "\u03c9": "w",
    # Greek capital
    "\u0391": "A", "\u0395": "E", "\u0399": "I", "\u039a": "K", "\u039f": "O",
    "\u03a1": "P", "\u03a4": "T", "\u03a5": "Y", "\u03a7": "X", "\u039d": "N",
    "\u03a9": "W",
}
HOMOGLYPH_TABLE = str.maketrans(CYRILLIC_GREEK_HOMOGLYPHS)

SENSITIVE_PREFIXES = (
    ".github/workflows/",
    ".github/scripts/check-pr-automerge-safety",
    "tools/copybara/",
    "tools/release/",
    "tools/package-export-smoke",
    "tools/release-provenance",
    "tools/build-aar.sh",
    "tools/build-xcframework.sh",
    "tools/workflow-secrets",
    "tools/workflow-freshness",
    "tools/check-branch-protection",
    "tools/check-required-checks",
    "tools/commit-message-guard",
    "tools/docs-token-guard",
    "tools/repo-integrity-guard",
    "tools/cov-floor-gate",
)


def _is_cf(c: str) -> bool:
    """Unicode category 'Cf' (format characters, including bidi controls and zero-width spaces)."""
    return unicodedata.category(c) == "Cf" or c in ("\xad", "\ufeff")


def _finish(norm: str) -> str:
    # Casefold, map hyphens, underscores, dots, slashes and common punctuation between words to
    # spaces, then collapse whitespace.
    norm = norm.casefold()
    norm = re.sub(r"[-_./:;,!?()\[\]{}'\"]+", " ", norm)
    return " " + " ".join(norm.split()) + " "


def normalize_forms(text: str) -> list[str]:
    """Every normalized shape a marker can hide in.

    Unicode Cf format characters (bidi overrides, zero-width spaces, joiners) are stripped.
    Both space-mapped and deleted forms are produced so markers cannot hide between words
    or inside words. Cyrillic and Greek homoglyphs are converted to ASCII equivalents.
    """
    if not text:
        return []
    nfkc = unicodedata.normalize("NFKC", text)
    mapped = nfkc.translate(HOMOGLYPH_TABLE)
    # Form 1: Cf characters mapped to space
    f1 = "".join(" " if _is_cf(c) else c for c in mapped)
    # Form 2: Cf characters deleted
    f2 = "".join("" if _is_cf(c) else c for c in mapped)
    return [_finish(f1), _finish(f2)]


def normalize_text(text: str) -> str:
    forms = normalize_forms(text)
    return forms[0] if forms else ""


def check_review_intent(title: str, body: str) -> list[str]:
    # Match phrases including:
    # do not merge, dont merge, dnm, wip, rfc (with optional digits), research,
    # hold, review only, needs review, please review, for review, under review,
    # not ready, draft, blocked, experiment, review required, awaiting review
    patterns = [
        (r"\bdo\s+not\s+merge\b", "do not merge"),
        (r"\bdont\s+merge\b", "dont merge"),
        (r"\bdnm\b", "dnm"),
        (r"\bw\s*i\s*p\b", "wip"),
        (r"\brfc\s*\d*\b", "rfc"),
        (r"\bresearch\b", "research"),
        (r"\bhold\b", "hold"),
        (r"\bhold\s+off\b", "hold off"),
        (r"\breview\s+only\b", "review only"),
        (r"\bneeds\s+review\b", "needs review"),
        (r"\bplease\s+review\b", "please review"),
        (r"\bfor\s+review\b", "for review"),
        (r"\bunder\s+review\b", "under review"),
        (r"\breview\s+required\b", "review required"),
        (r"\bawaiting\s+review\b", "awaiting review"),
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


def check_commit_messages(messages: list[str]) -> list[str]:
    reasons = []
    for msg in messages:
        if not msg:
            continue
        found = check_review_intent(msg, "")
        for item in found:
            reasons.append(f"commit message {item}")
    return reasons


def check_stale_approval(body: str, current_date: datetime.date | None = None) -> list[str]:
    if not body:
        return []
    if current_date is None:
        current_date = datetime.date.today()
    reasons = []
    matches = re.finditer(
        r"\b(?:owner|lead|maintainer)\s+approval\s+of\s+(\d{4}-\d{2}-\d{2})\b",
        body,
        re.IGNORECASE,
    )
    for m in matches:
        date_str = m.group(1)
        try:
            d = datetime.date.fromisoformat(date_str)
            if d < current_date:
                reasons.append(
                    f"PR description relies on stale approval date ({date_str} is prior to {current_date})"
                )
        except ValueError:
            pass
    if re.search(
        r"\b(?:blanket\s+approval|move\s+forward\s+anyway[^\n.]*approval)\b",
        body,
        re.IGNORECASE,
    ):
        reasons.append(
            "PR description relies on verbal or blanket approval; requires explicit PR review approval"
        )
    return reasons


def check_sensitive_files(files: list[str], reviews: list[dict]) -> list[str]:
    sensitive_modified = [f for f in files if any(f.startswith(p) for p in SENSITIVE_PREFIXES)]
    if not sensitive_modified:
        return []
    approved = any(r.get("state") == "APPROVED" for r in reviews)
    if not approved:
        summary = ", ".join(sensitive_modified[:3])
        if len(sensitive_modified) > 3:
            summary += f" and {len(sensitive_modified) - 3} more"
        return [
            f"PR modifies sensitive path(s) ({summary}) without explicit approved PR review (PROC-012)"
        ]
    return []


def _fetch_pr_data(
    pr_number: str, gh_token: str | None
) -> tuple[list[str], list[dict], list[str], str | None]:
    """Fetch changed files, reviews, and commit messages for PR via GitHub CLI.

    Fails CLOSED (PROC-012): returns an explicit error string on any failure,
    timeout, invalid JSON, or empty output from the GitHub CLI.
    """
    files: list[str] = []
    reviews: list[dict] = []
    commits: list[str] = []

    env = dict(os.environ)
    if gh_token:
        env["GH_TOKEN"] = gh_token

    cmd = [
        "gh",
        "pr",
        "view",
        pr_number,
        "--json",
        "files,reviews,commits",
    ]
    try:
        proc = subprocess.run(
            cmd, env=env, capture_output=True, text=True, check=False, timeout=30
        )
    except FileNotFoundError:
        return files, reviews, commits, "gh CLI not found in PATH"
    except subprocess.TimeoutExpired:
        return files, reviews, commits, f"gh pr view {pr_number} timed out after 30s"
    except Exception as e:
        return files, reviews, commits, f"gh pr view {pr_number} execution failed: {e}"

    if proc.returncode != 0:
        err = proc.stderr.strip() if proc.stderr else f"exit code {proc.returncode}"
        return files, reviews, commits, f"gh pr view {pr_number} failed: {err}"

    if not proc.stdout or not proc.stdout.strip():
        return files, reviews, commits, f"gh pr view {pr_number} returned empty output"

    try:
        data = json.loads(proc.stdout)
    except Exception as e:
        return files, reviews, commits, f"gh pr view {pr_number} returned invalid JSON: {e}"

    if not isinstance(data, dict):
        return files, reviews, commits, f"gh pr view {pr_number} returned non-dict JSON"

    raw_files = data.get("files")
    if raw_files is None:
        return files, reviews, commits, f"gh pr view {pr_number} response missing 'files' field"
    for f in raw_files:
        if isinstance(f, dict) and "path" in f:
            files.append(f["path"])

    raw_reviews = data.get("reviews")
    if raw_reviews is None:
        return files, reviews, commits, f"gh pr view {pr_number} response missing 'reviews' field"
    for r in raw_reviews:
        if isinstance(r, dict):
            reviews.append(r)

    for c in data.get("commits", []):
        if isinstance(c, dict):
            headline = c.get("messageHeadline", "")
            body = c.get("messageBody", "")
            commits.append(f"{headline}\n{body}".strip())

    return files, reviews, commits, None


def main() -> int:
    title = os.environ.get("TITLE", "")
    body = os.environ.get("BODY", "")

    # Optional overrides from environment (for unit testing)
    current_date_str = os.environ.get("CURRENT_DATE")
    current_date = (
        datetime.date.fromisoformat(current_date_str)
        if current_date_str
        else datetime.date.today()
    )

    files_raw = os.environ.get("CHANGED_FILES")
    reviews_raw = os.environ.get("PR_REVIEWS")
    commits_raw = os.environ.get("COMMIT_MESSAGES")

    files: list[str] = []
    reviews: list[dict] = []
    commits: list[str] = []

    if files_raw is not None:
        files = [f.strip() for f in re.split(r"[\n,]+", files_raw) if f.strip()]
    if reviews_raw is not None:
        reviews_trimmed = reviews_raw.strip()
        if reviews_trimmed.startswith("["):
            try:
                reviews = json.loads(reviews_trimmed)
            except Exception:
                reviews = []
        elif reviews_trimmed:
            for item in re.split(r"[\n,]+", reviews_trimmed):
                item = item.strip()
                if item:
                    reviews.append({"state": item.upper()})
    if commits_raw is not None:
        commits = [c.strip() for c in commits_raw.split("\x00") if c.strip()]
        if not commits:
            commits = [c.strip() for c in commits_raw.split("\n") if c.strip()]

    pr_number = os.environ.get("PR_NUMBER")
    gh_token = os.environ.get("GH_TOKEN")
    fetch_error = None
    if pr_number and (files_raw is None or reviews_raw is None or commits_raw is None):
        fetched_files, fetched_reviews, fetched_commits, fetch_err = _fetch_pr_data(
            pr_number, gh_token
        )
        if fetch_err:
            fetch_error = fetch_err
        else:
            if files_raw is None:
                if not fetched_files:
                    fetch_error = f"gh pr view {pr_number} returned empty changed files list"
                else:
                    files = fetched_files
            if reviews_raw is None:
                reviews = fetched_reviews
            if commits_raw is None:
                commits = fetched_commits

    reasons: list[str] = []
    reasons.extend(check_review_intent(title, body))
    reasons.extend(check_commit_messages(commits))
    reasons.extend(check_stale_approval(body, current_date))
    if fetch_error:
        reasons.append(
            f"GitHub CLI metadata query failed or returned empty data ({fetch_error}); refusing auto-merge (PROC-012)"
        )
    else:
        reasons.extend(check_sensitive_files(files, reviews))
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
