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

# A bare `new X()`, `X.from(...)`/`X(...)`, explicit globalThis/global/window/self access,
# destructuring, aliasing, or computed access to a denied global. Deliberately textual:
# the type system is exactly what failed to catch this, so this check does not consult it.
GLOBAL_OBJECTS = r"(?:globalThis|global|window|self|frames|top|parent)"

def violations(text):
    found = []
    text_clean = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    for line_no, line in enumerate(text_clean.splitlines(), start=1):
        code = line.split("//", 1)[0]
        if not code.strip():
            continue
        for name, reason in FORBIDDEN.items():
            # 1. Access on globalThis, global, window, self, frames, top, parent (property or optional chaining)
            if re.search(r"\b" + GLOBAL_OBJECTS + r"\s*(?:\?\.|\.)\s*\b" + name + r"\b", code):
                found.append((line_no, name, reason, line.strip()))
                continue
            # 2. Computed access on globalThis, global, window, self, frames, top, parent (quotes or backticks)
            if re.search(r"\b" + GLOBAL_OBJECTS + r"\s*(?:\?\.)?\s*\[\s*[\x22\x27\`]" + name + r"[\x22\x27\`]\s*\]", code):
                found.append((line_no, name, reason, line.strip()))
                continue
            # 3. Destructuring from globalThis, global, window, self, frames, top, parent
            if re.search(r"\{[^}]*\b" + name + r"\b[^}]*\}\s*=\s*" + GLOBAL_OBJECTS + r"\b", code):
                found.append((line_no, name, reason, line.strip()))
                continue
            # 4. Bare reference, call, instantiation, or aliasing
            code_no_strings = re.sub(r'"[^"\\]*(?:\\.[^"\\]*)*"|\x27[^\x27\\]*(?:\\.[^\x27\\]*)*\x27|`[^`\\]*(?:\\.[^`\\]*)*`', '""', code)
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
                found.append((line_no, name, reason, line.strip()))
                continue
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
