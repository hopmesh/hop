#!/usr/bin/env bash
# Self-test for tools/ble-threading-guard.sh. A guard nobody proves can FAIL is decoration, so this
# drives it against the real tree (must pass) and against fixtures that reproduce, one at a time, each
# way PLAT-002 was actually broken (must fail).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$ROOT/tools/ble-threading-guard.sh"
REAL="$ROOT/bearers/apple/HopBearerBle/Sources/HopBearerBle/BleBearer+Radio.swift"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fails=0

expect_pass() { # name file
  if BLE_THREADING_RADIO="$2" bash "$GUARD" >/dev/null 2>&1; then
    echo "ok   $1"
  else
    echo "FAIL $1 (guard rejected something it should accept)"
    BLE_THREADING_RADIO="$2" bash "$GUARD" 2>&1 | sed 's/^/       /'
    fails=1
  fi
}

expect_fail() { # name file
  if BLE_THREADING_RADIO="$2" bash "$GUARD" >/dev/null 2>&1; then
    echo "FAIL $1 (guard accepted a broken tree)"
    fails=1
  else
    echo "ok   $1"
  fi
}

expect_pass "the real tree is single-homed" "$REAL"

# 1. The exact regression: start()'s body back on the caller's thread.
sed 's/        bleQueue.async { \[weak self\] in/        if true {/' "$REAL" > "$TMP/no-start-hop.swift"
expect_fail "start() without a bleQueue hop is rejected" "$TMP/no-start-hop.swift"

# 2. The STATUS Timer scheduled off the run loop that owns it.
python3 - "$REAL" "$TMP/no-runloop.swift" <<'PY'
import sys
src = open(sys.argv[1]).read()
open(sys.argv[2], "w").write(src.replace("bleRunLoop.perform", "immediately"))
PY
expect_fail "a Timer scheduled off bleRunLoop is rejected" "$TMP/no-runloop.swift"

# 3. Teardown of the CB shells on the caller's thread.
python3 - "$REAL" "$TMP/sync-teardown.swift" <<'PY'
import re
import sys
src = open(sys.argv[1]).read()
i = src.index("public func stop()")
head, tail = src[:i], src[i:]
# Hoist the shell teardown above the dispatch, which is what the pre-fix code did.
tail = tail.replace("""        bleQueue.async { [weak self] in
            guard let self else { return }
            self.central?.stop(); self.central = nil
            self.peripheral?.stop(); self.peripheral = nil
        }""", """        central?.stop(); central = nil
        peripheral?.stop(); peripheral = nil
        bleQueue.async { [weak self] in _ = self }""", 1)
open(sys.argv[2], "w").write(head + tail)
PY
expect_fail "shell teardown before the bleQueue hop is rejected" "$TMP/sync-teardown.swift"

# 4. markStopped() moved after the dispatch, reopening the adopt window PLAT-001 closed.
python3 - "$REAL" "$TMP/late-mark.swift" <<'PY'
import sys
src = open(sys.argv[1]).read()
i = src.index("public func stop()")
head, tail = src[:i], src[i:]
tail = tail.replace("        markStopped()\n", "", 1)
tail = tail.replace("            guard let self else { return }\n            self.central?.stop()",
                    "            guard let self else { return }\n            self.markStopped()\n            self.central?.stop()", 1)
open(sys.argv[2], "w").write(head + tail)
PY
expect_fail "markStopped() after the dispatch is rejected" "$TMP/late-mark.swift"

# 5. Fails closed on a file with no lifecycle at all, rather than passing vacuously.
echo "// nothing here" > "$TMP/empty.swift"
expect_fail "a file with no start()/stop() is rejected, not passed vacuously" "$TMP/empty.swift"

exit "$fails"
