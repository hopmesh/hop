#!/usr/bin/env bash
# PLAT-002: keep the Apple BLE bearer's CoreBluetooth state single-homed on bleQueue, and its bleRunLoop
# timers invalidated on bleRunLoop.
#
# WHY A GREP GUARD AND NOT A TEST. `Central`/`CentralCore` and `Peripheral`/`PeripheralCore` are
# documented as owned exclusively by `bleQueue` and therefore carry NO locks (CentralCore.swift). The
# only way to break that is to touch them from another thread, and the only way to prove the fix by
# execution is to drive real CoreBluetooth: CB has no headless/simulator support and its delegate
# argument types have no public initializers, so `swift test` cannot construct a Central or a Peripheral
# at all. That is not a gap this guard invented; it is why BleBearer+Radio.swift is excluded from CI line
# coverage in the first place.
#
# The consequence was measured, not assumed: reverting all three PLAT-002 controls (start/stop bodies
# back on the caller's thread, the STATUS Timer scheduled and invalidated off bleRunLoop) left the
# HopBearerBle suite at 117 tests, 0 failures. A fix nothing can redden is a fix that comes back. So the
# structural property gets a structural gate: the shells are CONSTRUCTED and TORN DOWN on bleQueue, and
# the Timer is scheduled and invalidated on bleRunLoop. This is the same cheap-substitute reasoning as
# tools/ble-backoff-parity.sh, which pins a schedule no shared core can force.
#
# WHAT THIS CANNOT SEE: it checks the lifecycle call sites in the bearer's own start()/stop(), not every
# conceivable access from elsewhere. It catches the regression that actually happened (a body running on
# whichever thread called it) and it fails closed if the file is restructured so the anchors disappear.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RADIO="${BLE_THREADING_RADIO:-$ROOT/bearers/apple/HopBearerBle/Sources/HopBearerBle/BleBearer+Radio.swift}"

python3 - "$RADIO" <<'PY'
import re
import sys

path = sys.argv[1]
failures = []

try:
    src = open(path).read()
except OSError as e:
    print(f"FAIL: cannot read {path}: {e}")
    sys.exit(1)


def body(name):
    """The text of `public func <name>() { ... }` in the BleBearer extension, brace-matched."""
    m = re.search(r"public func " + re.escape(name) + r"\([^)]*\)\s*\{", src)
    if not m:
        return None
    i = m.end() - 1
    depth = 0
    for j in range(i, len(src)):
        if src[j] == "{":
            depth += 1
        elif src[j] == "}":
            depth -= 1
            if depth == 0:
                return src[i : j + 1]
    return None


start, stop = body("start"), body("stop")
if start is None:
    failures.append("no `public func start()` found in the bearer's radio extension")
if stop is None:
    failures.append("no `public func stop()` found in the bearer's radio extension")

def at(body, needle):
    """Index of `needle` in `body`, or None. Never raises: a missing anchor is a reported failure, not
    a crash, because this guard runs against trees that HAVE regressed."""
    i = body.find(needle)
    return None if i < 0 else i


if start is not None:
    # The CB shells own bleQueue-only state, so they must be CONSTRUCTED on bleQueue.
    hop = at(start, "bleQueue.async")
    if hop is None:
        failures.append("start() does not dispatch to bleQueue; the CB shells would be built off-queue")
    for shell in ("Peripheral(", "Central("):
        where = at(start, shell)
        if where is None:
            failures.append(f"start() no longer constructs {shell.rstrip('(')}; guard anchor lost")
        elif hop is None or hop > where:
            failures.append(f"{shell.rstrip('(')} is constructed BEFORE the bleQueue hop in start()")
    # The STATUS Timer lives on bleRunLoop, which has CFRunLoop thread affinity.
    if "Timer(" in start and "bleRunLoop.perform" not in start:
        failures.append("start() schedules a Timer without hopping to bleRunLoop")

if stop is not None:
    # Teardown touches the same bleQueue-only state.
    hop = at(stop, "bleQueue.async")
    if hop is None:
        failures.append("stop() does not dispatch the radio teardown to bleQueue")
    for call in ("central?.stop()", "peripheral?.stop()"):
        where = at(stop, call)
        if where is None:
            failures.append(f"stop() no longer calls {call}; guard anchor lost")
        elif hop is None or hop > where:
            failures.append(f"{call} runs BEFORE the bleQueue hop in stop()")
    # A Timer must be invalidated on the thread whose run loop it was added to.
    if "invalidate()" in stop and "bleRunLoop.perform" not in stop:
        failures.append("stop() invalidates a Timer without hopping to bleRunLoop")
    # The consumer-visible half of PLAT-001 is synchronous, before anything is dispatched.
    mark = at(stop, "markStopped()")
    if mark is None:
        failures.append("stop() does not call markStopped(); the no-new-links guarantee is not synchronous")
    elif hop is not None and mark > hop:
        failures.append("markStopped() runs AFTER the dispatch; a link could be adopted in the window")

if failures:
    for f in failures:
        print(f"FAIL: {f}")
    sys.exit(1)
print("ok: Apple BLE radio lifecycle is single-homed (bleQueue shells, bleRunLoop timers)")
PY
