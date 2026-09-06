#!/usr/bin/env python3
"""Keep the React Native SDK off runtime globals Hermes does not provide.

Hermes is React Native's default engine and it is an ECMAScript engine, not a browser. Web APIs are
absent unless the app polyfills them. Two things conspire to hide that from every check this package
runs:

  * `tsconfig.json` sets `"lib": ["ES2020", "DOM"]` and `"types": ["node"]`, so the compiler is told
    the whole browser and Node surface exists. `new TextDecoder()` typechecks perfectly.
  * the JS layer's tests run under `node --test`, and Node HAS these globals, so a round-trip test
    of the offending code passes green.

So a global that does not exist on the target runtime is invisible at build time AND at test time,
and surfaces only in a consuming app. `bytesToUtf8` shipped `new TextDecoder()` on exactly that
path. It threw `ReferenceError` inside the inbound-message accept handler, which meant every
received message and channel publication died before the store saw it and the core redelivered it
on the next pump tick: an app that looked idle while throwing four times a second. That is why the
denylist below is a guard and not a lint preference.

The list is deliberately narrow. It names globals that are genuinely absent or unreliable on
Hermes, not everything a browser has. `TextEncoder` is on it because it landed in Hermes only
recently and this package's peer range is `react-native: "*"`, so an older Hermes has neither half
of the pair. If a global here becomes universally safe across that range, delete its row and say so
in the commit; do not add an inline exemption.
"""

import re
import sys
from pathlib import Path

PKG = "sdk/react-native"
SRC = f"{PKG}/src"

# global -> why it is not safe to reference on Hermes.
FORBIDDEN = {
    "TextDecoder": "absent in Hermes; the SDK ships bytesToUtf8 in src/base64.ts",
    "TextEncoder": "present only in recent Hermes, and the peer range is react-native '*'; "
    "the SDK ships utf8ToBytes in src/base64.ts",
    "structuredClone": "absent in Hermes",
    "atob": "absent in Hermes; use fromBase64 in src/base64.ts",
    "btoa": "absent in Hermes; use toBase64 in src/base64.ts",
    "Buffer": "Node-only; never present in a React Native app",
    "URLSearchParams": "React Native's URL support is partial; do not rely on it in the SDK",
    "FinalizationRegistry": "not dependable on Hermes",
    "WeakRef": "not dependable on Hermes",
}

# Base runtime global objects in JS/TS environments.
BASE_GLOBAL_OBJECTS = ("globalThis", "global", "window", "self", "frames", "top", "parent")


def strip_comments_keep_lines(text):
    """Strip comments while preserving exact line numbers and string contents."""
    pattern = r'("(?:[^"\\]|\\.)*"|\x27(?:[^\x27\\]|\\.)*\x27|`(?:[^`\\]|\\.)*`)|(/\*[\s\S]*?\*/|//[^\r\n]*)'

    def repl(m):
        if m.group(1):
            return m.group(1)
        comment = m.group(2)
        if comment.startswith("//"):
            return " " * len(comment)
        return "\n" * comment.count("\n") + " " * (
            len(comment) - comment.rfind("\n") - 1 if "\n" in comment else len(comment)
        )

    return re.sub(pattern, repl, text)


def find_destructuring_blocks(text_clean, globals_set):
    """Find all { ... } = global_object destructuring blocks with balanced braces."""
    blocks = []
    i = 0
    n = len(text_clean)
    while i < n:
        if text_clean[i] == "{":
            start_offset = i + 1
            depth = 1
            j = i + 1
            while j < n and depth > 0:
                if text_clean[j] == "{":
                    depth += 1
                elif text_clean[j] == "}":
                    depth -= 1
                j += 1
            if depth == 0:
                end_offset = j - 1
                after = text_clean[j:]
                m = re.match(r"^\s*=\s*([A-Za-z_$][\w$]*)", after)
                if m:
                    rhs_name = m.group(1)
                    if rhs_name in globals_set:
                        inner = text_clean[start_offset:end_offset]
                        blocks.append((inner, start_offset, rhs_name))
                i = j
                continue
        i += 1
    return blocks


def find_global_aliases(text_clean):
    """Track local variables aliasing globalThis/global/window/self/etc."""
    globals_set = set(BASE_GLOBAL_OBJECTS)
    changed = True
    while changed:
        changed = False
        # 1. Direct assignment: const/let/var/bare alias = global_object;
        globals_re = r"(?:" + "|".join(re.escape(g) for g in sorted(globals_set, key=len, reverse=True)) + r")"
        assign_pat = (
            r"(?:(?:const|let|var)\s+)?([A-Za-z_$][\w$]*)\s*=\s*(?:\(?\s*)"
            + globals_re
            + r"(?:\s*(?:\?\.|\.)\s*"
            + globals_re
            + r")*\s*(?:\)?)[\s;]"
        )
        for m in re.finditer(assign_pat, text_clean):
            var_name = m.group(1)
            if var_name not in globals_set and var_name not in ("const", "let", "var", "if", "while", "return"):
                globals_set.add(var_name)
                changed = True

        # 2. Destructuring assignment: { ... } = global_object;
        for inner, _, rhs_name in find_destructuring_blocks(text_clean, globals_set):
            for m in re.finditer(r"\b([A-Za-z_$][\w$]*)\s*:\s*([A-Za-z_$][\w$]*)\b", inner):
                key, alias = m.group(1), m.group(2)
                if key in globals_set and alias not in globals_set:
                    globals_set.add(alias)
                    changed = True
    return globals_set


def violations(text):
    found = []
    lines = text.splitlines()
    text_clean = strip_comments_keep_lines(text)
    globals_set = find_global_aliases(text_clean)
    globals_re = r"(?:" + "|".join(re.escape(g) for g in sorted(globals_set, key=len, reverse=True)) + r")"
    forbidden_re = r"(?:" + "|".join(re.escape(k) for k in FORBIDDEN.keys()) + r")"

    def get_line_info(offset):
        line_no = text_clean[:offset].count("\n") + 1
        line_str = lines[line_no - 1].strip() if line_no <= len(lines) else ""
        return line_no, line_str

    reported = set()

    # 1. Property access on global objects or aliases (including multiline): obj.Name or obj?.Name
    for m in re.finditer(r"\b" + globals_re + r"\s*(?:\?\.|\.)\s*\b(" + forbidden_re + r")\b", text_clean):
        name = m.group(1)
        name_offset = m.start(1)
        line_no, line_str = get_line_info(name_offset)
        if (line_no, name) not in reported:
            reported.add((line_no, name))
            found.append((line_no, name, FORBIDDEN[name], line_str))

    # 2. Computed bracket access on global objects or aliases (including multiline): obj["Name"]
    for m in re.finditer(
        r"\b" + globals_re + r"\s*(?:\?\.)?\s*\[\s*[\x22\x27\`](" + forbidden_re + r")[\x22\x27\`]\s*\]",
        text_clean,
    ):
        name = m.group(1)
        name_offset = m.start(1)
        line_no, line_str = get_line_info(name_offset)
        if (line_no, name) not in reported:
            reported.add((line_no, name))
            found.append((line_no, name, FORBIDDEN[name], line_str))

    # 3. Destructuring from global objects or aliases (including multiline and nested)
    for inner, inner_start, rhs_name in find_destructuring_blocks(text_clean, globals_set):
        for name in FORBIDDEN.keys():
            for nm in re.finditer(r"\b" + re.escape(name) + r"\b", inner):
                name_offset = inner_start + nm.start()
                line_no, line_str = get_line_info(name_offset)
                if (line_no, name) not in reported:
                    reported.add((line_no, name))
                    found.append((line_no, name, FORBIDDEN[name], line_str))

    # 4. Bare reference, call, instantiation, or aliasing (line by line)
    for line_no, line in enumerate(text_clean.splitlines(), start=1):
        code = line.split("//", 1)[0]
        if not code.strip():
            continue
        code_no_strings = re.sub(
            r'"[^"\\]*(?:\\.[^"\\]*)*"|\x27[^\x27\\]*(?:\\.[^\x27\\]*)*\x27|`[^`\\]*(?:\\.[^`\\]*)*`',
            '""',
            code,
        )
        for name, reason in FORBIDDEN.items():
            if (line_no, name) in reported:
                continue
            is_bare_violation = False
            for m in re.finditer(r"(?<![\w.$])" + name + r"\b", code_no_strings):
                start, end = m.start(), m.end()
                after = code_no_strings[end:].lstrip()
                if after.startswith(":") and not after.startswith("::"):
                    continue
                if after.startswith("?:"):
                    continue
                pre = code_no_strings[:start].rstrip()
                if pre.endswith(":") or pre.endswith("type") or pre.endswith("interface") or pre.endswith("as"):
                    continue
                is_bare_violation = True
                break
            if is_bare_violation:
                line_str = lines[line_no - 1].strip() if line_no <= len(lines) else ""
                reported.add((line_no, name))
                found.append((line_no, name, reason, line_str))

    found.sort(key=lambda x: (x[0], x[1]))
    return found

def main(argv):
    # An optional root makes the guard testable against a sandbox tree, which is how its own
    # self-test proves it can fail. Defaults to the repo this file lives in.
    root = Path(argv[1]).resolve() if len(argv) > 1 else Path(__file__).resolve().parent.parent
    src = root / SRC
    if not src.is_dir():
        print(f"::error:: {SRC} not found under {root}")
        return 1
    files = sorted(src.rglob("*.ts")) + sorted(src.rglob("*.tsx"))
    if not files:
        print(f"::error:: no TypeScript sources under {SRC}; the guard would pass vacuously")
        return 1
    failures = []
    for path in files:
        rel = path.relative_to(root)
        for line_no, name, reason, line in violations(path.read_text(encoding="utf-8")):
            failures.append(f"{rel}:{line_no}: {name} is not safe on Hermes ({reason})\n    {line}")
    if failures:
        print("::error:: React Native SDK references globals Hermes may not provide:")
        for failure in failures:
            print(f"  {failure}")
        print(
            "\nA missing global throws ReferenceError at runtime only. If it lands inside an accept "
            "path, delivery stalls silently. Implement it in src/base64.ts (pure, dependency-free) "
            "or pass the value in from the caller."
        )
        return 1
    print(
        f"rn hermes globals guard OK: {len(files)} source files, "
        f"none reference any of {len(FORBIDDEN)} denied globals"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
