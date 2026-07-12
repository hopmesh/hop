#!/usr/bin/env python3
# cov-floor-gate.py (pass-18 F-CI-7): gate Swift line coverage from an `llvm-cov export` JSON stream,
# enforcing an aggregate floor AND a per-file floor. Reads the JSON on stdin.
#
#   xcrun llvm-cov export <bin> -instr-profile <prof> -ignore-filename-regex '...' Sources/... \
#     | python3 tools/cov-floor-gate.py <src-root> <aggregate-floor> <per-file-floor>
#
# Why JSON, not `llvm-cov report` + `awk $(NF-3)`: the text report's column COUNT depends on whether
# branch-coverage columns are present, so a positional field index silently reads the wrong metric
# (function % instead of line %, which reads higher) and produces a FALSE PASS if a future toolchain
# changes the table layout. The JSON export keys each metric by name (summary.lines.percent), so it
# cannot drift. This is the robustness fix for the HopDriver coverage floor.
#
# Denominator: every file under <src-root> that llvm-cov reported (the -ignore-filename-regex already
# dropped the device/thread-bound files upstream, so they never reach here). Exits 1 on any breach.
import json
import os
import sys


def main() -> int:
    if len(sys.argv) != 4:
        sys.stderr.write("usage: cov-floor-gate.py <src-root> <aggregate-floor> <per-file-floor>\n")
        return 2
    srcroot = os.path.abspath(sys.argv[1]).rstrip(os.sep) + os.sep
    agg_floor = float(sys.argv[2])
    file_floor = float(sys.argv[3])

    try:
        doc = json.load(sys.stdin)
        data = doc["data"][0]["files"]
    except (ValueError, KeyError, IndexError) as exc:
        print("FAIL: could not parse llvm-cov export JSON (%s)" % exc)
        return 1

    # Scope to the package's own source root so a dependency's Sources never dilutes the denominator.
    files = [f for f in data if os.path.abspath(f["filename"]).startswith(srcroot)]
    if not files:
        print("FAIL: llvm-cov export produced no source files under %s (empty denominator)" % srcroot)
        return 1

    covered = sum(f["summary"]["lines"]["covered"] for f in files)
    total = sum(f["summary"]["lines"]["count"] for f in files)
    aggregate = 100.0 * covered / total if total else 0.0
    print("aggregate line coverage (%d files, non-device denominator): %.2f%%" % (len(files), aggregate))

    bad = False
    if aggregate < agg_floor:
        print("FAIL: aggregate %.2f%% is below the %.0f%% floor" % (aggregate, agg_floor))
        bad = True
    else:
        print("OK: aggregate at or above the %.0f%% floor" % agg_floor)

    for f in sorted(files, key=lambda x: x["filename"]):
        pct = f["summary"]["lines"]["percent"]
        if pct < file_floor:
            print("FAIL: %s at %.2f%% is below the %.0f%% per-file floor"
                  % (os.path.basename(f["filename"]), pct, file_floor))
            bad = True
    if not bad:
        print("OK: every source file is at or above the %.0f%% per-file floor" % file_floor)

    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
