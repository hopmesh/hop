from __future__ import annotations

import argparse
import html
import re
import sys
from pathlib import Path
from typing import Any, Iterable

from ledger import CLOSURE_STATE_KEYS, GRADE_KEYS, load_ledger, sorted_findings, summarize_ledger, validate_ledger


CSS = r"""
:root {
  color-scheme: dark;
  --ink: #080c0e;
  --panel: #101719;
  --panel-2: #151f22;
  --line: #2a393d;
  --text: #edf5f2;
  --muted: #93a7a2;
  --signal: #71f7b6;
  --cyan: #67dbea;
  --amber: #f5c86a;
  --orange: #ff8a57;
  --red: #ff5c68;
  --shadow: rgba(0, 0, 0, 0.34);
  --mesh: rgba(113, 247, 182, 0.055);
}

:root[data-theme="light"] {
  color-scheme: light;
  --ink: #edf2ef;
  --panel: #ffffff;
  --panel-2: #f4f8f6;
  --line: #c7d4cf;
  --text: #0d1715;
  --muted: #52645f;
  --signal: #087a4a;
  --cyan: #08798a;
  --amber: #8b6200;
  --orange: #ad431d;
  --red: #b31f31;
  --shadow: rgba(17, 42, 35, 0.14);
  --mesh: rgba(8, 122, 74, 0.07);
}

* { box-sizing: border-box; }
html { scroll-behavior: smooth; }
body {
  margin: 0;
  background:
    radial-gradient(circle at 14% 8%, var(--mesh), transparent 26rem),
    linear-gradient(120deg, transparent 0 49.7%, var(--mesh) 49.8% 50.2%, transparent 50.3%) 0 0 / 54px 54px,
    var(--ink);
  color: var(--text);
  font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  line-height: 1.55;
}

a { color: var(--cyan); }
button, summary { font: inherit; }
button:focus-visible, summary:focus-visible, a:focus-visible { outline: 3px solid var(--cyan); outline-offset: 3px; }
code, pre, .mono { font-family: "SFMono-Regular", Consolas, "Liberation Mono", monospace; }

.shell { width: min(1500px, calc(100% - 32px)); margin: 0 auto; }
.topbar {
  position: sticky;
  top: 0;
  z-index: 20;
  border-bottom: 1px solid var(--line);
  background: color-mix(in srgb, var(--ink) 88%, transparent);
  backdrop-filter: blur(18px);
}
.topbar-inner { display: flex; align-items: center; justify-content: space-between; min-height: 58px; gap: 18px; }
.brand { display: flex; align-items: center; gap: 10px; font-weight: 800; letter-spacing: 0.13em; text-transform: uppercase; }
.brand svg { width: 28px; height: 28px; color: var(--signal); }
.nav { display: flex; align-items: center; gap: 14px; overflow-x: auto; }
.nav a { color: var(--muted); text-decoration: none; font-size: 0.82rem; white-space: nowrap; }
.nav a:hover { color: var(--text); }
.theme-toggle { border: 1px solid var(--line); color: var(--text); background: var(--panel); border-radius: 999px; padding: 7px 11px; cursor: pointer; }

.hero { padding: 88px 0 52px; border-bottom: 1px solid var(--line); }
.eyebrow { color: var(--signal); font: 700 0.74rem/1.2 "SFMono-Regular", monospace; letter-spacing: 0.18em; text-transform: uppercase; }
h1 { max-width: 980px; margin: 14px 0 18px; font-size: clamp(2.7rem, 7vw, 7rem); line-height: 0.92; letter-spacing: -0.055em; }
.assessment { max-width: 900px; margin: 0; color: var(--muted); font-size: clamp(1.08rem, 2.2vw, 1.48rem); }
.hero-meta { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 28px; }
.chip { border: 1px solid var(--line); border-radius: 999px; padding: 6px 10px; background: var(--panel); color: var(--muted); font: 650 0.76rem/1.1 "SFMono-Regular", monospace; }
.chip.internal { color: var(--amber); border-color: color-mix(in srgb, var(--amber) 45%, var(--line)); }

main section { padding: 58px 0; border-bottom: 1px solid var(--line); }
.section-head { display: grid; grid-template-columns: 84px minmax(0, 1fr); gap: 20px; margin-bottom: 28px; }
.section-index { color: var(--signal); font: 700 0.72rem/1.2 "SFMono-Regular", monospace; letter-spacing: 0.16em; }
h2 { margin: 0; font-size: clamp(1.8rem, 4vw, 3.6rem); line-height: 1; letter-spacing: -0.035em; }
.section-copy { grid-column: 2; max-width: 850px; margin: -10px 0 0; color: var(--muted); }

.grade-grid { display: grid; grid-template-columns: repeat(5, minmax(0, 1fr)); gap: 12px; }
.grade-card, .metric-card, .priority-card, .coverage-card, .verification-card, .note-card {
  border: 1px solid var(--line);
  background: linear-gradient(155deg, var(--panel-2), var(--panel));
  box-shadow: 0 18px 46px var(--shadow);
}
.grade-card { min-height: 190px; padding: 20px; display: flex; flex-direction: column; justify-content: space-between; }
.grade-label { color: var(--muted); font-size: 0.78rem; letter-spacing: 0.08em; text-transform: uppercase; }
.grade { color: var(--signal); font-size: clamp(2.2rem, 5vw, 4.7rem); font-weight: 850; line-height: 0.9; letter-spacing: -0.05em; }
.grade.previous { color: var(--muted); font-size: 0.78rem; font-weight: 600; letter-spacing: 0; }
.grade-rationale { color: var(--muted); font-size: 0.84rem; }

.metrics { display: grid; grid-template-columns: repeat(5, minmax(0, 1fr)); gap: 10px; margin-bottom: 24px; }
.metric-card { padding: 16px; }
.metric-value { display: block; font-size: 2rem; font-weight: 850; line-height: 1; }
.metric-label { display: block; margin-top: 8px; color: var(--muted); font-size: 0.74rem; text-transform: uppercase; letter-spacing: 0.1em; }
.landscape { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 10px; margin-top: 14px; }
.landscape-group { border: 1px solid var(--line); background: var(--panel); padding: 16px; }
.landscape-group h3 { margin: 0 0 12px; color: var(--muted); font-size: 0.72rem; letter-spacing: 0.1em; text-transform: uppercase; }
.count-row { display: flex; justify-content: space-between; gap: 12px; padding: 6px 0; border-top: 1px solid var(--line); }
.count-row strong { color: var(--signal); }

.strengths { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 10px; margin: 0; padding: 0; list-style: none; }
.strengths li { border-left: 3px solid var(--signal); background: var(--panel); padding: 14px 16px; }

.priority-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 14px; }
.priority-card { padding: 22px; }
.priority-id { color: var(--cyan); font: 700 0.78rem/1 "SFMono-Regular", monospace; }
.priority-card h3 { margin: 10px 0; font-size: 1.25rem; }
.priority-meta { color: var(--muted); font-size: 0.82rem; }

.filters { display: flex; flex-wrap: wrap; gap: 8px; margin: 0 0 20px 104px; }
.filter { border: 1px solid var(--line); background: var(--panel); color: var(--muted); border-radius: 999px; padding: 7px 11px; cursor: pointer; }
.filter[aria-pressed="true"] { color: var(--ink); background: var(--signal); border-color: var(--signal); }
.filter-status { margin: -12px 0 20px 104px; color: var(--muted); font-size: 0.78rem; }

.finding-list { display: grid; gap: 12px; }
.finding { border: 1px solid var(--line); background: var(--panel); box-shadow: 0 16px 40px var(--shadow); }
.finding[hidden] { display: none; }
.finding summary { position: relative; display: grid; grid-template-columns: 9px 108px minmax(0, 1fr) auto; align-items: center; gap: 15px; padding: 18px 44px 18px 20px; cursor: pointer; list-style: none; }
.finding summary::-webkit-details-marker { display: none; }
.finding summary::after { position: absolute; right: 18px; content: "+"; color: var(--cyan); font-weight: 800; }
.finding[open] summary::after { content: "-"; }
.severity-rail { align-self: stretch; background: var(--muted); }
.finding[data-severity="critical"] .severity-rail { background: var(--red); }
.finding[data-severity="high"] .severity-rail { background: var(--orange); }
.finding[data-severity="medium"] .severity-rail { background: var(--amber); }
.finding[data-severity="low"] .severity-rail { background: var(--cyan); }
.finding[data-severity="info"] .severity-rail { background: var(--signal); }
.finding-id { font: 750 0.78rem/1 "SFMono-Regular", monospace; color: var(--cyan); }
.finding-title { font-weight: 780; font-size: 1rem; }
.finding-status { color: var(--muted); font: 650 0.72rem/1 "SFMono-Regular", monospace; text-transform: uppercase; }
.finding-body { border-top: 1px solid var(--line); padding: 24px 30px 30px; }
.finding-meta { display: flex; flex-wrap: wrap; gap: 7px; margin-bottom: 24px; }
.finding-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 18px 28px; }
.field h4 { margin: 0 0 6px; color: var(--signal); font-size: 0.73rem; text-transform: uppercase; letter-spacing: 0.12em; }
.field p { margin: 0; }
.field.full { grid-column: 1 / -1; }
.evidence-list, .plain-list { margin: 8px 0 0; padding-left: 20px; }
.evidence-list li, .plain-list li { margin: 8px 0; }
.evidence-location { color: var(--cyan); font-family: "SFMono-Regular", monospace; font-size: 0.82rem; }
.closure-matrix { display: grid; grid-template-columns: repeat(7, minmax(0, 1fr)); gap: 6px; }
.closure-cell { border: 1px solid var(--line); background: var(--panel-2); padding: 9px; }
.closure-cell span { display: block; color: var(--muted); font-size: 0.66rem; letter-spacing: 0.08em; text-transform: uppercase; }
.closure-cell strong { display: block; margin-top: 5px; color: var(--amber); font-size: 0.74rem; overflow-wrap: anywhere; }
.closure-cell strong.validated { color: var(--signal); }
.closure-cell strong.not_applicable { color: var(--muted); }

.coverage-grid { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 12px; }
.coverage-card { padding: 18px; }
.coverage-card h3 { margin: 0 0 6px; font-size: 1rem; }
.coverage-path { color: var(--cyan); font: 0.76rem/1.3 "SFMono-Regular", monospace; overflow-wrap: anywhere; }
.coverage-status { display: inline-block; margin-top: 12px; color: var(--signal); font: 700 0.72rem/1 "SFMono-Regular", monospace; text-transform: uppercase; }
.coverage-status.scoped_out { color: var(--amber); }
.coverage-detail { margin-top: 12px; color: var(--muted); font-size: 0.84rem; }

.table-wrap { overflow-x: auto; border: 1px solid var(--line); background: var(--panel); }
table { width: 100%; border-collapse: collapse; min-width: 760px; }
th, td { padding: 12px 14px; text-align: left; border-bottom: 1px solid var(--line); vertical-align: top; }
th { color: var(--muted); font-size: 0.72rem; text-transform: uppercase; letter-spacing: 0.1em; }
td { font-size: 0.88rem; }

.two-col { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 14px; }
.verification-card, .note-card { padding: 18px; }
.verification-card h3, .note-card h3 { margin: 0 0 8px; font-size: 1rem; }
.result { color: var(--signal); font: 700 0.72rem/1 "SFMono-Regular", monospace; text-transform: uppercase; }
.result.failed { color: var(--red); }
.result.blocked, .result.not_run { color: var(--amber); }
.command { margin-top: 10px; color: var(--cyan); font-size: 0.77rem; overflow-wrap: anywhere; }
.muted { color: var(--muted); }
.empty { border: 1px dashed var(--line); color: var(--muted); padding: 28px; text-align: center; }

footer { padding: 34px 0 64px; color: var(--muted); font-size: 0.8rem; }

@media (max-width: 1050px) {
  .grade-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .metrics { grid-template-columns: repeat(3, minmax(0, 1fr)); }
  .coverage-grid, .landscape { grid-template-columns: repeat(2, minmax(0, 1fr)); }
}

@media (max-width: 700px) {
  .shell { width: min(100% - 20px, 1500px); }
  .nav a { display: none; }
  .hero { padding-top: 58px; }
  .section-head { grid-template-columns: 1fr; }
  .section-copy { grid-column: 1; margin-top: 0; }
  .grade-grid, .metrics, .priority-grid, .strengths, .coverage-grid, .landscape, .two-col, .finding-grid { grid-template-columns: 1fr; }
  .filters, .filter-status { margin-left: 0; }
  .finding summary { grid-template-columns: 7px 82px minmax(0, 1fr); }
  .finding-status { grid-column: 3; }
  .finding-body { padding: 20px; }
  .closure-matrix { grid-template-columns: repeat(2, minmax(0, 1fr)); }
}

@media (prefers-reduced-motion: reduce) {
  html { scroll-behavior: auto; }
}

@media print {
  :root { color-scheme: light; --ink: #fff; --panel: #fff; --panel-2: #fff; --line: #b7c2be; --text: #111; --muted: #444; --shadow: transparent; --mesh: transparent; }
  .topbar, .filters, .filter-status, .theme-toggle { display: none !important; }
  .hero { padding-top: 20px; }
  main section { break-before: auto; }
  .finding, .grade-card, .priority-card, .coverage-card, .verification-card, .note-card { break-inside: avoid; box-shadow: none; }
  .finding:not([open]) .finding-body { display: block; }
  .finding[hidden] { display: block; }
  a { color: inherit; text-decoration: none; }
}
"""


JS = r"""
(() => {
  const root = document.documentElement;
  const toggle = document.querySelector('.theme-toggle');
  toggle?.addEventListener('click', () => {
    const light = root.dataset.theme !== 'light';
    root.dataset.theme = light ? 'light' : 'dark';
    toggle.setAttribute('aria-pressed', String(light));
  });

  const buttons = [...document.querySelectorAll('.filter')];
  const findings = [...document.querySelectorAll('.finding')];
  const status = document.querySelector('.filter-status');
  buttons.forEach((button) => button.addEventListener('click', () => {
    const active = button.getAttribute('aria-pressed') === 'true';
    buttons.forEach((item) => item.setAttribute('aria-pressed', 'false'));
    if (!active) button.setAttribute('aria-pressed', 'true');
    const key = !active ? button.dataset.key : null;
    const value = !active ? button.dataset.value : null;
    findings.forEach((finding) => {
      finding.hidden = Boolean(key && finding.dataset[key] !== value);
    });
    const visible = findings.filter((finding) => !finding.hidden).length;
    if (status) status.textContent = `${visible} of ${findings.length} findings shown`;
  }));
})();
"""


def esc(value: Any) -> str:
    return html.escape(str(value), quote=True)


def label(value: str) -> str:
    return value.replace("_", " ").title()


def render_string_list(items: Iterable[str], class_name: str = "plain-list") -> str:
    values = list(items)
    if not values:
        return '<p class="muted">None recorded.</p>'
    return f'<ul class="{class_name}">' + "".join(f"<li>{esc(item)}</li>" for item in values) + "</ul>"


def render_count_group(title: str, counts: dict[str, int]) -> str:
    rows = "".join(
        f'<div class="count-row"><span>{esc(label(key))}</span><strong>{count}</strong></div>'
        for key, count in sorted(counts.items(), key=lambda item: (-item[1], item[0]))
    )
    return f'<article class="landscape-group"><h3>{esc(title)}</h3>{rows}</article>'


def render_claim_metadata(item: dict[str, Any]) -> str:
    sources = "".join(
        f'<span> / {esc(source["location"])} ({esc(source["retrieved_at"])})</span>'
        for source in item.get("external_sources", [])
    )
    return (
        f'{esc(", ".join(item["provenance"]))} / {esc(item["visibility"])}'
        f"{sources}"
    )


def grade_delta(key: str, current: str, previous: str) -> str:
    if current == previous:
        return "Unchanged"
    if "Not graded" in {current, previous}:
        return "Not comparable"
    order = (
        ["A+", "A", "A-", "B+", "B", "B-", "C+", "C", "C-", "D+", "D", "D-", "F", "Not graded"]
        if key != "operational_readiness"
        else ["Validated", "Partially validated", "Not validated", "Not graded"]
    )
    current_index = order.index(current)
    previous_index = order.index(previous)
    if current_index < previous_index:
        return "Improved"
    if current_index > previous_index:
        return "Regressed"
    return "Unchanged"


def render_grade_cards(grades: dict[str, Any]) -> str:
    cards = []
    for key in GRADE_KEYS:
        item = grades[key]
        previous = item.get("previous")
        previous_html = (
            f'<div class="grade previous">Previous: {esc(previous)} | Delta: '
            f'{esc(grade_delta(key, item["grade"], previous))}</div>'
            if previous
            else ""
        )
        cards.append(
            '<article class="grade-card">'
            f'<div class="grade-label">{esc(label(key))}</div>'
            f'<div class="grade">{esc(item["grade"])}</div>'
            f"{previous_html}"
            f'<div class="grade-rationale">{esc(item["rationale"])}</div>'
            f'<div class="grade-rationale mono">Evidence: {esc(", ".join(item["evidence"]) or "Not graded")}</div>'
            f'<div class="grade-rationale mono">Provenance: {render_claim_metadata(item)}</div>'
            "</article>"
        )
    return "".join(cards)


def render_evidence(items: list[dict[str, str]]) -> str:
    return '<ul class="evidence-list">' + "".join(
        "<li>"
        + f'<div class="evidence-location">{esc(item["location"])}</div>'
        + f'<div><strong>{esc(label(item["kind"]))} / {esc(label(item["provenance"]))}:</strong> {esc(item["detail"])}</div>'
        + (f'<div class="muted">Retrieved: {esc(item["retrieved_at"])}</div>' if item.get("retrieved_at") else "")
        + "</li>"
        for item in items
    ) + "</ul>"


def field(title: str, content: str, *, full: bool = False) -> str:
    full_class = " full" if full else ""
    return f'<div class="field{full_class}"><h4>{esc(title)}</h4>{content}</div>'


def render_closure_state(state: dict[str, str]) -> str:
    return '<div class="closure-matrix">' + "".join(
        '<div class="closure-cell">'
        f'<span>{esc(label(key))}</span>'
        f'<strong class="{esc(value)}">{esc(label(value))}</strong>'
        "</div>"
        for key in CLOSURE_STATE_KEYS
        for value in (state[key],)
    ) + "</div>"


def render_finding(item: dict[str, Any]) -> str:
    opened = " open" if item["severity"] in {"critical", "high"} else ""
    status_text = (
        f'{item["previous_status"]} -> {item["status"]}' if item.get("previous_status") else item["status"]
    )
    body = "".join(
        [
            field("Invariant", f'<p>{esc(item["invariant"])}</p>', full=True),
            field("Threat model", f'<p>{esc(item["threat_model"])}</p>'),
            field("Impact", f'<p>{esc(item["impact"])}</p>'),
            field("Business impact", f'<p>{esc(item["business_impact"])}</p>'),
            field("Root cause", f'<p>{esc(item["root_cause"])}</p>'),
            field("Scenario", f'<p>{esc(item["scenario"])}</p>', full=True),
            field("Evidence", render_evidence(item["evidence"]), full=True),
            field("Coverage gap", f'<p>{esc(item["coverage_gap"])}</p>'),
            field("Remediation boundary", f'<p>{esc(item["remediation_boundary"])}</p>'),
            field("Closure contract", render_string_list(item["closure_contract"]), full=True),
            field("Closure evidence", render_string_list(item["closure_evidence"]), full=True),
            field("Closure state", render_closure_state(item["closure_state"]), full=True),
            field("Relationships", render_string_list(item["relationships"]), full=True),
            field("Residual and limits", render_string_list(item["residual"]), full=True),
        ]
    )
    return (
        f'<details class="finding" data-severity="{esc(item["severity"])}" '
        f'data-domain="{esc(item["domain"])}" data-status="{esc(item["status"])}"{opened}>'
        "<summary>"
        '<span class="severity-rail" aria-hidden="true"></span>'
        f'<span class="finding-id">{esc(item["id"])}</span>'
        f'<span class="finding-title">{esc(item["title"])}</span>'
        f'<span class="finding-status">{esc(status_text)}</span>'
        "</summary>"
        '<div class="finding-body">'
        '<div class="finding-meta">'
        f'<span class="chip">{esc(item["severity"])}</span>'
        f'<span class="chip">original: {esc(item["original_severity"])}</span>'
        f'<span class="chip">{esc(item["confidence"])} confidence</span>'
        f'<span class="chip">{esc(item["domain"])}</span>'
        f'<span class="chip">{esc(item["component"])}</span>'
        f'<span class="chip">{esc(item["vector"])}</span>'
        f'<span class="chip">owner: {esc(item["owner_class"])}</span>'
        "</div>"
        f'<div class="finding-grid">{body}</div>'
        "</div></details>"
    )


def render_coverage(data: dict[str, Any]) -> str:
    inventory = {item["id"]: item for item in data["inventory"]}
    cards = []
    for item in sorted(data["coverage"], key=lambda entry: entry["inventory_id"]):
        component = inventory[item["inventory_id"]]
        detail = item.get("rationale") or ", ".join(item["vectors"])
        cards.append(
            '<article class="coverage-card">'
            f'<h3>{esc(component["name"])}</h3>'
            f'<div class="coverage-path">{esc(component["path"])}</div>'
            f'<span class="coverage-status {esc(item["status"])}">{esc(item["status"])}</span>'
            f'<div class="coverage-detail"><strong>Reviewers:</strong> {esc(", ".join(item["reviewers"]) or "None")}</div>'
            f'<div class="coverage-detail">{esc(detail)}</div>'
            f'<div class="coverage-detail"><strong>Evidence:</strong> {esc(", ".join(item["evidence"]) or "Unavailable")}</div>'
            "</article>"
        )
    return "".join(cards)


# Break the document across lines before writing it. The renderer used to emit the entire <body> as
# ONE line: 373,892 characters, 96% of a 387KB report. That is not a cosmetic problem. GitHub's
# dorny/paths-filter failed outright on a PR carrying such a file, which reddened "Detect changed
# areas" and cascaded to every downstream job, and the same report's 407KB JSON ledger passed in the
# same PR because it is pretty-printed. Newlines between block-level closers are insignificant in
# HTML outside <pre>, and any literal tag inside a <pre> has already been escaped by esc(), so this
# cannot alter rendering.
LINE_BREAK_BLOCKS = ("</section>", "</header>", "</footer>", "</article>", "</table>",
                     "</tr>", "</ul>", "</ol>", "</details>", "</nav>", "</main>", "</div>")


def line_break_html(html: str) -> str:
    for tag in LINE_BREAK_BLOCKS:
        html = html.replace(tag, tag + "\n")
    return re.sub(r"\n{3,}", "\n\n", html)


def render_report(data: dict[str, Any]) -> str:
    errors = validate_ledger(data)
    if errors:
        raise ValueError("ledger is invalid:\n" + "\n".join(errors))

    audit = data["audit"]
    summary = data["executive_summary"]
    counts = summarize_ledger(data)
    findings = sorted_findings(data)
    classification_class = "internal" if audit["classification"] == "internal" else ""

    severity_metrics = "".join(
        '<article class="metric-card">'
        f'<span class="metric-value">{counts["severity"].get(severity, 0)}</span>'
        f'<span class="metric-label">{esc(severity)}</span>'
        "</article>"
        for severity in ("critical", "high", "medium", "low", "info")
    )

    priorities = "".join(
        '<article class="priority-card">'
        f'<div class="priority-id">{esc(item["finding_id"])}</div>'
        f'<h3>{esc(item["next_control"])}</h3>'
        f'<p>{esc(item["why_now"])}</p>'
        f'<div class="priority-meta">Owner class: {esc(item["owner_class"])}</div>'
        f'<div class="priority-meta">Dependencies: {esc(", ".join(item["dependencies"]) or "None")}</div>'
        f'<div class="priority-meta mono">Provenance: {render_claim_metadata(item)}</div>'
        "</article>"
        for item in summary["lean_in"]
    ) or '<div class="empty">No priority findings recorded.</div>'

    finding_html = "".join(render_finding(item) for item in findings) or '<div class="empty">No accepted findings.</div>'
    filters = "".join(
        f'<button class="filter" data-key="severity" data-value="{severity}" aria-pressed="false">{severity.title()} {counts["severity"].get(severity, 0)}</button>'
        for severity in ("critical", "high", "medium", "low", "info")
        if counts["severity"].get(severity, 0)
    )

    refuted_rows = "".join(
        "<tr>"
        f'<td class="mono">{esc(item["id"])}</td>'
        f'<td><strong>{esc(item["title"])}</strong><div>{esc(item["hypothesis"])}</div></td>'
        f'<td class="mono">{esc(item["component"])}</td>'
        f'<td>{esc(item["disproof"])}{render_string_list(item["evidence"])}'
        f'<div class="muted mono">{render_claim_metadata(item)}</div></td>'
        "</tr>"
        for item in data["refuted_candidates"]
    ) or '<tr><td colspan="4" class="muted">No refuted candidates recorded.</td></tr>'

    verification = "".join(
        '<article class="verification-card">'
        f'<span class="result {esc(item["result"])}">{esc(item["result"])}</span>'
        f'<h3>{esc(item["name"])}</h3>'
        f'<div class="command mono">{esc(item["command"])}</div>'
        f'<p class="muted">{esc(item["scope"])} at {esc(item["commit"])}</p>'
        f'<p>{esc(item.get("notes", ""))}</p>'
        f'<p class="muted mono">{render_claim_metadata(item)}</p>'
        "</article>"
        for item in data["verification"]
    ) or '<div class="empty">No verification recorded.</div>'

    limits = "".join(
        '<article class="note-card"><h3>Evidence limit</h3>'
        f'<p>{esc(item["text"])}</p>'
        f'<p class="muted mono">{render_claim_metadata(item)}</p></article>'
        for item in data["limits"]
    ) or '<div class="empty">No evidence limits recorded.</div>'
    operations = "".join(
        '<article class="note-card"><h3>External action</h3>'
        f'<p>{esc(item["text"])}</p>'
        f'<p class="muted mono">{render_claim_metadata(item)}</p></article>'
        for item in data["operational_actions"]
    ) or '<div class="empty">No external actions recorded.</div>'

    strengths = "".join(
        "<li>"
        f'<div>{esc(item["claim"])}</div>'
        f'<div class="muted mono">Evidence: {esc(", ".join(item["evidence"]))}</div>'
        f'<div class="muted mono">Provenance: {render_claim_metadata(item)}</div>'
        "</li>"
        for item in summary["strengths"]
    ) or "<li>No verified strengths recorded.</li>"
    landscape = "".join(
        [
            render_count_group("By domain", dict(counts["domain"])),
            render_count_group("By status", dict(counts["status"])),
            render_count_group("By component", dict(counts["component"])),
        ]
    )
    contracts = "".join(
        "<tr>"
        f'<td>{esc(item["name"])}</td>'
        f'<td class="mono">{esc(item["version"])}</td>'
        f'<td class="mono">{esc(item["location"])}</td>'
        "</tr>"
        for item in data["contracts"]
    ) or '<tr><td colspan="3" class="muted">No versioned contracts recorded.</td></tr>'
    baseline_chip = ""
    if audit.get("baseline"):
        baseline_chip = (
            f'<span class="chip">baseline: {esc(audit["baseline"]["id"])}</span>'
            f'<span class="chip mono">{esc(audit["baseline"]["commit"])}</span>'
        )

    body = (
        '<header class="topbar"><div class="shell topbar-inner">'
        '<div class="brand">'
        '<svg viewBox="0 0 32 32" aria-hidden="true"><circle cx="16" cy="16" r="13" fill="none" stroke="currentColor"/><path d="M6 18c5-8 9 8 14 0s6 1 6 1M8 11c4-4 6 5 10 1s6 2 6 2" fill="none" stroke="currentColor" stroke-width="1.5"/></svg>'
        "HOP audit</div>"
        '<nav class="nav" aria-label="Report sections">'
        '<a href="#scorecard">Scorecard</a><a href="#priorities">Lean in</a><a href="#findings">Findings</a><a href="#coverage">Coverage</a><a href="#verification">Evidence</a>'
        '<button class="theme-toggle" type="button" aria-pressed="false">Theme</button>'
        "</nav></div></header>"
        '<div class="hero"><div class="shell">'
        f'<div class="eyebrow">{esc(audit["mode"])} / round {esc(audit["round"])}</div>'
        f'<h1>{esc(audit["title"])}</h1>'
        f'<p class="assessment">{esc(summary["assessment"])}</p>'
        f'<p class="muted mono">Provenance: {render_claim_metadata({"provenance": summary["assessment_provenance"], "visibility": summary["assessment_visibility"], "external_sources": summary.get("assessment_external_sources", [])})}</p>'
        '<div class="hero-meta">'
        f'<span class="chip {classification_class}">{esc(audit["classification"])}</span>'
        f'<span class="chip">{esc(label(data["publication"]["boundary"]))}</span>'
        f'<span class="chip mono">{esc(data["publication"]["output_root"])}</span>'
        f'<span class="chip">{esc(audit["date"])}</span>'
        f'<span class="chip">{esc(audit["branch"])}</span>'
        f'<span class="chip">{esc(audit["remote"])}</span>'
        f'<span class="chip">{"dirty" if audit["dirty"] else "clean"} worktree</span>'
        f'<span class="chip">round {esc(audit["round"])}</span>'
        f'<span class="chip mono">{esc(audit["commit"])}</span>'
        f"{baseline_chip}"
        "</div></div></div>"
        "<main>"
        '<section id="scorecard"><div class="shell">'
        '<div class="section-head"><div class="section-index">01 / SIGNAL</div><h2>Independent scorecard</h2><p class="section-copy">Grades stay separate so technical strength cannot hide business, process, validation, or operating gaps.</p></div>'
        f'<div class="grade-grid">{render_grade_cards(data["grades"])}</div>'
        f'<div class="metrics" style="margin-top:16px">{severity_metrics}</div>'
        f'<div class="landscape">{landscape}</div>'
        f'<ul class="strengths">{strengths}</ul>'
        "</div></section>"
        '<section id="priorities"><div class="shell">'
        '<div class="section-head"><div class="section-index">02 / VECTOR</div><h2>Where to lean in</h2><p class="section-copy">Priority and dependency order only. Each card names the next control and owner class.</p></div>'
        f'<div class="priority-grid">{priorities}</div>'
        "</div></section>"
        '<section id="findings"><div class="shell">'
        '<div class="section-head"><div class="section-index">03 / LEDGER</div><h2>Accepted findings</h2><p class="section-copy">Every finding carries evidence, a violated invariant, and a closure contract.</p></div>'
        f'<div class="filters" role="group" aria-label="Finding filters">{filters}</div>'
        f'<p class="filter-status" role="status" aria-live="polite">{len(findings)} of {len(findings)} findings shown</p>'
        f'<div class="finding-list">{finding_html}</div>'
        "</div></section>"
        '<section id="coverage"><div class="shell">'
        '<div class="section-head"><div class="section-index">04 / COVERAGE</div><h2>Component map</h2><p class="section-copy">Every discovered component is reviewed or explicitly scoped out.</p></div>'
        f'<div class="coverage-grid">{render_coverage(data)}</div>'
        "</div></section>"
        '<section id="refuted"><div class="shell">'
        '<div class="section-head"><div class="section-index">05 / REFUTED</div><h2>What survived challenge</h2><p class="section-copy">Refuted hypotheses prevent later rounds from repeating dead ends.</p></div>'
        '<div class="table-wrap"><table><thead><tr><th>ID</th><th>Hypothesis</th><th>Component</th><th>Disproof</th></tr></thead>'
        f'<tbody>{refuted_rows}</tbody></table></div>'
        "</div></section>"
        '<section id="verification"><div class="shell">'
        '<div class="section-head"><div class="section-index">06 / EVIDENCE</div><h2>Verification and chronology</h2><p class="section-copy">Commands, results, scope, and source SHA remain explicit.</p></div>'
        f'<div class="two-col">{verification}</div>'
        "</div></section>"
        '<section id="limits"><div class="shell">'
        '<div class="section-head"><div class="section-index">07 / LIMITS</div><h2>External truth</h2><p class="section-copy">Unknowns and owner-held work remain visible rather than being converted into source claims.</p></div>'
        f'<div class="two-col">{limits}{operations}</div>'
        "</div></section>"
        '<section id="method"><div class="shell">'
        '<div class="section-head"><div class="section-index">08 / METHOD</div><h2>Adversarial method</h2><p class="section-copy">Live inventory, independent component and vector finders, separate refuters, evidence and severity adjudication, a completeness critic, and prewritten closure contracts.</p></div>'
        f'<p class="muted">Scope: {esc(audit["scope"])}</p>'
        '<div class="table-wrap"><table><thead><tr><th>Contract</th><th>Version</th><th>Evidence</th></tr></thead>'
        f'<tbody>{contracts}</tbody></table></div>'
        "</div></section>"
        "</main>"
        '<footer><div class="shell">Generated from validated ledger '
        f'<span class="mono">{esc(audit["id"])}</span>. Counts and grades were not hand-maintained. '
        f'Publication boundary: {esc(label(data["publication"]["boundary"]))}.</div></footer>'
    )

    return (
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        f"<title>{esc(audit['title'])}</title>"
        f"<style>{CSS}</style></head><body>{body}<script>{JS}</script></body></html>"
    )


def write_report(data: dict[str, Any], output: str | Path) -> None:
    path = Path(output)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(line_break_html(render_report(data)), encoding="utf-8")



def main() -> int:
    parser = argparse.ArgumentParser(description="Render a validated HOP adversarial audit ledger as HTML")
    parser.add_argument("ledger", help="Path to the JSON ledger")
    parser.add_argument("output", help="Path for the generated HTML report")
    args = parser.parse_args()

    try:
        data = load_ledger(args.ledger)
        write_report(data, args.output)
    except (OSError, ValueError) as error:
        print(f"report rendering failed: {error}", file=sys.stderr)
        return 1

    print(f"report rendered: {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
