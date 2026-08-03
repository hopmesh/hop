#!/usr/bin/env python3
"""Generate THIRD-PARTY-NOTICES.md for the crates compiled into a shipped hop binary.

Why this exists. libhop statically links 171 third-party crates. Most are MIT or Apache-2.0, and
BOTH require that the copyright notice and licence text travel with the distributed binary. Nothing
shipped one: not the xcframework, not the AAR, not the ESP32 artifacts. That is a straightforward
licence-compliance gap, and the only reason it went unnoticed is that no tool looked.

What it walks. The SHIPPING graph only: resolve edges from the named root, skipping dev-dependency
edges, because a test-only crate is not in the artifact and listing it would overstate the notice
rather than understate it. Build-dependency edges ARE followed by default, since a proc-macro's
output is compiled in even though the macro crate itself is not linked; --no-build drops them if you
want the strict linked-only set.

What it cannot do. It reports what each crate DECLARES. A crate whose declared SPDX expression
offers a choice ("MIT OR Apache-2.0") is recorded with the whole expression rather than a pick,
because choosing is a legal decision and not one a script should quietly make on your behalf.

Usage:
    python3 tools/gen-third-party-notices.py --root hop --out THIRD-PARTY-NOTICES.md
    python3 tools/gen-third-party-notices.py --root hop --check   # CI: is the committed file current
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import subprocess
import sys

# Licences whose terms require the notice and licence text to accompany a binary distribution.
# Anything here MUST end up in the generated file with its text, or the notice is incomplete.
ATTRIBUTION_REQUIRED = ("MIT", "BSD", "ISC", "Apache", "Zlib", "Unicode", "MPL", "BSL", "OpenSSL")

# Licence file names crates actually use, in the order we prefer them.
LICENSE_NAMES = (
    "LICENSE-MIT", "LICENSE-APACHE", "LICENSE.md", "LICENSE", "LICENSE.txt",
    "COPYING", "COPYRIGHT", "NOTICE", "UNLICENSE",
)


def shipping_packages(root_name: str, follow_build: bool) -> list[dict]:
    """Every package reachable from `root_name` over non-dev edges, root excluded."""
    md = json.loads(subprocess.run(
        ["cargo", "metadata", "--format-version", "1"],
        capture_output=True, text=True, check=True).stdout)
    pkgs = {p["id"]: p for p in md["packages"]}
    nodes = {n["id"]: n for n in md["resolve"]["nodes"]}
    roots = [i for i, p in pkgs.items() if p["name"] == root_name]
    if not roots:
        sys.exit(f"gen-third-party-notices: no package named {root_name!r} in the workspace")
    seen: set[str] = set()
    stack = list(roots)
    while stack:
        cur = stack.pop()
        if cur in seen:
            continue
        seen.add(cur)
        for dep in nodes[cur]["deps"]:
            kinds = {k.get("kind") for k in dep.get("dep_kinds", [])}
            if kinds and kinds <= {"dev"}:
                continue                       # test-only, never in the artifact
            if not follow_build and kinds and kinds <= {"build"}:
                continue
            stack.append(dep["pkg"])
    for r in roots:
        seen.discard(r)
    # Workspace-local crates carry their own LICENSE.md and are OUR code, not third party.
    ws = set(md.get("workspace_members", []))
    return sorted((pkgs[i] for i in seen if i not in ws), key=lambda p: (p["name"], p["version"]))


def license_text(pkg: dict) -> tuple[str, str] | None:
    """The crate's own licence text, read from its unpacked source in the cargo registry."""
    src = pathlib.Path(pkg["manifest_path"]).parent
    for name in LICENSE_NAMES:
        f = src / name
        if f.is_file():
            try:
                t = f.read_text(errors="replace").strip()
            except OSError:
                continue
            if t:
                return name, t
    return None


def needs_attribution(expr: str) -> bool:
    return any(tok.lower() in expr.lower() for tok in ATTRIBUTION_REQUIRED)


def inventory(root: str, pkgs: list[dict]) -> str:
    """The part of the notice that is a pure function of the lockfile.

    Deliberately excludes the embedded licence BODIES. Those are read from the local cargo registry,
    which only holds a crate's unpacked source once something has built it, so a macOS workstation
    and a Linux CI runner legitimately disagree about which bodies are available. Comparing the full
    rendered file made the check host-dependent and it failed on its own first CI run. What must
    never silently go stale is the SET of crates being shipped, and that comes from the lockfile.
    """
    out = [f"root={root}"]
    for p in pkgs:
        out.append(f"{p['name']} {p['version']} {p.get('license') or 'UNDECLARED'}")
    return "\n".join(out) + "\n"


def render(root: str, pkgs: list[dict]) -> str:
    missing = [p for p in pkgs if needs_attribution(p.get("license") or "") and not license_text(p)]
    by_license: dict[str, list[dict]] = {}
    for p in pkgs:
        by_license.setdefault(p.get("license") or "UNDECLARED", []).append(p)

    out: list[str] = []
    out.append(f"# Third-party notices for `{root}`")
    out.append("")
    out.append("GENERATED FILE. Regenerate with:")
    out.append("")
    out.append("```")
    out.append(f"python3 tools/gen-third-party-notices.py --root {root} --out THIRD-PARTY-NOTICES.md")
    out.append("```")
    out.append("")
    out.append(f"This binary statically links {len(pkgs)} third-party crates. Their licences, chiefly")
    out.append("MIT and Apache-2.0, require that the copyright notice and licence text accompany a")
    out.append("distribution, so this file ships alongside every built artifact.")
    out.append("")
    out.append("Where a crate offers a CHOICE of licence, the full expression is recorded rather than a")
    out.append("selection: picking one is a legal decision and not one this generator makes for you.")
    out.append("")
    out.append("## Summary")
    out.append("")
    out.append("| Licence | Crates |")
    out.append("| --- | ---: |")
    for lic in sorted(by_license, key=lambda k: (-len(by_license[k]), k)):
        out.append(f"| `{lic}` | {len(by_license[lic])} |")
    out.append("")
    if missing:
        out.append("## Crates whose licence text could not be read")
        out.append("")
        out.append("Their declared licence requires attribution but no licence file was found in the")
        out.append("published crate. Obtain the text from the crate's repository before distributing.")
        out.append("")
        for p in missing:
            out.append(f"- `{p['name']} {p['version']}` ({p.get('license')}) {p.get('repository') or ''}".rstrip())
        out.append("")
    out.append("## Crates")
    out.append("")
    for p in pkgs:
        lic = p.get("license") or "UNDECLARED"
        repo = p.get("repository") or ""
        out.append(f"### {p['name']} {p['version']}")
        out.append("")
        out.append(f"- Licence: `{lic}`")
        if repo:
            out.append(f"- Source: {repo}")
        if p.get("authors"):
            out.append(f"- Authors: {', '.join(p['authors'])}")
        got = license_text(p)
        if got:
            fname, text = got
            out.append("")
            out.append(f"<details><summary>{fname}</summary>")
            out.append("")
            out.append("```")
            out.append(text)
            out.append("```")
            out.append("")
            out.append("</details>")
        out.append("")
    return "\n".join(out) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default="hop", help="crate whose shipped binary this describes")
    ap.add_argument("--out", default="THIRD-PARTY-NOTICES.md")
    ap.add_argument("--check", action="store_true", help="fail if the committed file is out of date")
    ap.add_argument("--no-build", action="store_true", help="drop build-dependency edges too")
    a = ap.parse_args()

    pkgs = shipping_packages(a.root, follow_build=not a.no_build)
    text = render(a.root, pkgs)
    out = pathlib.Path(a.out)

    if a.check:
        if not out.is_file():
            print(f"third-party-notices: MISSING {out}. Run the generator and commit it.", file=sys.stderr)
            return 1
        # Compare the INVENTORY, not the rendered file. The rendered file embeds licence bodies read
        # from the local cargo registry, which differs between a workstation and a CI runner, so a
        # whole-file diff is host-dependent and cannot be a gate. The crate set is what must not drift.
        committed = out.read_text()
        listed = set(re.findall(r"^### (\S+) (\S+)$", committed, re.M))
        wanted = {(p["name"], p["version"]) for p in pkgs}
        missing = sorted(wanted - listed)
        extra = sorted(listed - wanted)
        if missing or extra:
            print(f"third-party-notices: STALE {out}. The shipped crate set changed but the notice "
                  f"did not.", file=sys.stderr)
            for n, v in missing[:10]:
                print(f"  missing from the notice: {n} {v}", file=sys.stderr)
            for n, v in extra[:10]:
                print(f"  in the notice but no longer shipped: {n} {v}", file=sys.stderr)
            print(f"  Regenerate:\n    python3 tools/gen-third-party-notices.py --root {a.root} "
                  f"--out {a.out}", file=sys.stderr)
            return 1
        print(f"third-party-notices: OK ({len(pkgs)} crates listed in {out})")
        return 0

    out.write_text(text)
    print(f"third-party-notices: wrote {out} ({len(pkgs)} crates)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
