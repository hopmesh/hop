#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Hop test harness primitives. Uniform send/verify/fg-bg/log across Android (adb) and iOS (devicectl).
#   Android send : hopdemo://send deep link (am start)         : fires bearer.sendTo, no UI taps
#   iOS send     : hopdemo://send via devicectl --payload-url  : onOpenURL -> sendTo (env fallback)
#   Verify rx    : Android files/messages.json ; iOS Documents/automation.json (.rx)
#   Verify ack   : sender side delivered=true (END-TO-END crypto proof the dest received it)
#   bg/fg        : Android KEYCODE_HOME / monkey ; iOS launch Settings / launch app
#
# Source devices.sh first. addrs.env (name->addr) is produced by refresh-addrs.sh.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=devices.sh
source "$HERE/devices.sh"
# shellcheck disable=SC1091
[ -f "$HERE/addrs.env" ] && source "$HERE/addrs.env"
# quality-net-10: scratch dir defaults under the OS temp dir (portable), not a hardcoded absolute path
# into one machine's session scratch. Override with TK_WORK.
WORK="${TK_WORK:-${TMPDIR:-/tmp}/hop-testkit}"
mkdir -p "$WORK"

# quality-net-11: portability. The device wrappers below bound each call with a timeout so a dead
# device can't hang the harness. `timeout` is GNU coreutils; on macOS it may only be present as
# `gtimeout` (brew coreutils), and some minimal environments lack both - fall back to running the
# command directly (unbounded) with a warning rather than failing to source. Also requires bash >= 4
# for associative arrays; check + warn.
if command -v timeout >/dev/null 2>&1; then _TO() { timeout "$@"; }
elif command -v gtimeout >/dev/null 2>&1; then _TO() { gtimeout "$@"; }
else
  echo "testkit: WARNING no 'timeout'/'gtimeout' found - device calls run UNBOUNDED (a dead device can hang)." >&2
  _TO() { shift; "$@"; } # drop the duration arg, run directly
fi
if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "testkit: WARNING bash >= 4 recommended (found ${BASH_VERSION:-unknown}); some features may not work." >&2
fi

# Every device call goes through these so a dead / half-attached device can't hang the harness:
# raw `adb -s <serial>` BLOCKS forever waiting for an offline-but-known device, and `devicectl`
# can stall on an unavailable UDID. Bounding each call turns a hang into a fast, skippable failure.
DEV_TO="${TK_DEV_TIMEOUT:-25}"
adbx()  { _TO "$DEV_TO" adb "$@"; }
dctlx() { _TO "$DEV_TO" xcrun devicectl "$@"; }

# Settle delay between consecutive sends. Android coalesces VIEW intents fired <~100ms apart and
# silently drops one, so tk_send sleeps this long after each send so each intent registers. Default
# 0.7s (unchanged behavior); a soak can tune it (e.g. TK_SEND_SETTLE=0.3 to push send rate, or higher
# to be gentler on a slow device) without editing the harness.
SEND_SETTLE="${TK_SEND_SETTLE:-0.7}"

# --- self address ------------------------------------------------------------
tk_self_addr() {            # tk_self_addr <id>  -> base58 address (or empty)
  local id="$1" plat handle
  plat=$(dev_platform "$id"); handle=$(dev_handle "$id")
  if [ "$plat" = android ]; then
    adbx -s "$handle" logcat -d -s HOPLOG 2>/dev/null | grep "HOPAUTO self=" | tail -1 | sed -E 's/.*HOPAUTO self=([1-9A-HJ-NP-Za-km-z]+).*/\1/'
  else
    tk_pull_automation "$id" >/dev/null 2>&1
    python3 -c "import json,sys;print(json.load(open('$WORK/$id.automation.json')).get('self',''))" 2>/dev/null
  fi
}

# --- pull iOS automation.json -> $WORK/<id>.automation.json ------------------
tk_pull_automation() {      # tk_pull_automation <id>
  local id="$1" udid; udid=$(dev_handle "$id")
  local out="$WORK/$id.automation.json"
  rm -f "$out"
  # appDataContainer Documents dir; try a couple source spellings.
  dctlx device copy from --device "$udid" --domain-type appDataContainer \
    --domain-identifier "$BUNDLE" --source Documents/automation.json --destination "$out" >/dev/null 2>&1 \
  || dctlx device copy from --device "$udid" --domain-type appDataContainer \
    --user mobile --domain-identifier "$BUNDLE" --source Documents/automation.json --destination "$out" >/dev/null 2>&1
  [ -s "$out" ] && echo "$out"
}

# --- drive a send ------------------------------------------------------------
# iOS send strategy (quality-net-12): PREFER the hopdemo:// URL scheme over --payload-url. It opens the
# URL on the app WITHOUT a terminate/cold-relaunch, driving the SAME onOpenURL -> HopBearer.sendTo path
# the Android deep link uses. This is the fix for the iPad-origin gap: the HOP_AUTO launch-env path
# force-relaunches and its env injection did not reliably reach every iOS fleet member (bush/ipad), so
# iPad-origin scenarios were untestable. --payload-url is a first-class devicectl flag ("A URL to pass
# to the application for it to open"), so this is a real, supported trigger. We fall back to the
# cold-launch env path only if the URL launch fails, preserving the previous behavior.
#
# TK_IOS_SEND=env forces the legacy env path (useful to test cold-launch send specifically).
tk_send() {                 # tk_send <from-id> <to-addr> <marker>
  local id="$1" to="$2" mark="$3" plat handle
  plat=$(dev_platform "$id"); handle=$(dev_handle "$id")
  if [ "$plat" = android ]; then
    adbx -s "$handle" shell "am start -a android.intent.action.VIEW -d 'hopdemo://send?to=$to&text=$mark'" >/dev/null 2>&1
    # Android coalesces VIEW intents fired back-to-back (LAUNCH_MULTIPLE) and silently drops
    # one when sends are <~100ms apart. Settle between consecutive sends so each registers.
    # Delay is TK_SEND_SETTLE (default 0.7s); soaks can tune it.
    sleep "$SEND_SETTLE"
  elif [ "${TK_IOS_SEND:-url}" = url ]; then
    # URL-scheme trigger: activate the app and hand it hopdemo://send (onOpenURL -> sendTo). Works on a
    # running app (no terminate), so an iPad already in the fleet can originate a send. If the URL
    # launch fails, fall back to the legacy cold-relaunch env path (and log it, so a silent iOS send
    # failure is visible rather than looking like a delivered-but-lost message).
    if ! dctlx device process launch --device "$handle" --activate \
      --payload-url "hopdemo://send?to=$to&text=$mark" "$BUNDLE" >/dev/null 2>&1; then
      echo "testkit: tk_send $id: URL-scheme launch failed, falling back to HOP_AUTO env cold-relaunch (mark=$mark)" >&2
      dctlx device process launch --device "$handle" --terminate-existing \
        --environment-variables "{\"HOP_AUTO\":\"send|$to|$mark\"}" "$BUNDLE" >/dev/null 2>&1 \
      || echo "testkit: tk_send $id: env fallback ALSO failed; iOS send likely did not fire (mark=$mark)" >&2
    fi
    sleep "$SEND_SETTLE"
  else
    # Legacy path (TK_IOS_SEND=env): cold relaunch with the send command in the env; app fires ~3s later.
    dctlx device process launch --device "$handle" --terminate-existing \
      --environment-variables "{\"HOP_AUTO\":\"send|$to|$mark\"}" "$BUNDLE" >/dev/null 2>&1
  fi
}

# --- bearer control (PLAT-001 device leg) -----------------------------------
# Drives the SAME setTransportEnabled the UI switch calls, via the DEBUG-only hopdemo://bearer link.
# Without this the per-transport toggle is reachable only by tapping a screen, so PLAT-001's closure
# contract cannot be re-run or regressed. Both hooks are DEBUG-gated in the apps.
#
# IMPORTANT, and the reason these are two calls and not one: setTransportEnabled is ASYNCHRONOUS on
# both platforms (it hands off to a bearer-control thread). Reading state in the same breath races the
# toggle and reports the OLD value, which reads as "the toggle failed" when it simply had not applied.
# So tk_bearer flips, and tk_bearerstates reads AFTER a settle.
tk_bearer() {               # tk_bearer <id> <tag> <on|off>
  local id="$1" tag="$2" want="$3" plat handle en
  case "$want" in
    on|true|1)   en=true;;
    off|false|0) en=false;;
    *) echo "testkit: tk_bearer: want must be on|off, got '$want'" >&2; return 2;;
  esac
  plat=$(dev_platform "$id"); handle=$(dev_handle "$id")
  if [ "$plat" = android ]; then
    adbx -s "$handle" shell "am start -a android.intent.action.VIEW -d 'hopdemo://bearer?tag=$tag&enabled=$en'" >/dev/null 2>&1
    sleep "$SEND_SETTLE"
  else
    dctlx device process launch --device "$handle" --activate \
      --payload-url "hopdemo://bearer?tag=$tag&enabled=$en" "$BUNDLE" >/dev/null 2>&1 \
      || { echo "testkit: tk_bearer $id: URL launch failed, transport NOT toggled (tag=$tag want=$en)" >&2; return 1; }
    sleep "$SEND_SETTLE"
  fi
}

# Ask the app to print the BearerManager's own view. Reads states AND live link counts together,
# because PLAT-001 is about the two AGREEING: a transport reported disabled must carry no links.
tk_bearerstates() {         # tk_bearerstates <id>
  local id="$1" plat handle
  plat=$(dev_platform "$id"); handle=$(dev_handle "$id")
  if [ "$plat" = android ]; then
    adbx -s "$handle" shell "am start -a android.intent.action.VIEW -d 'hopdemo://bearerstates'" >/dev/null 2>&1
    sleep 1
    adbx -s "$handle" shell "logcat -d -t 400 | grep 'HOPAUTO bearerstates' | tail -1" 2>/dev/null
  else
    dctlx device process launch --device "$handle" --activate \
      --payload-url "hopdemo://bearerstates" "$BUNDLE" >/dev/null 2>&1 || return 1
    sleep 1
    echo "testkit: tk_bearerstates $id: read the line from idevicesyslog (HOPLAB HOPAUTO bearerstates)" >&2
  fi
}

# --- BLE Lab dormant switch (multi-app coexistence fixture) ------------------
# HopBleLab is the ONLY thing that reproduces the multi-app BLE defect: two hop-embedded apps on one
# iOS device publish the SAME service UUID with different L2CAP PSMs, so a remote central reads
# whichever the GATT stack returns and dials the wrong one. Measured on hardware: HopDemo psm=192,
# HopBleLab psm=193, an Android read 193 while trying to reach HopDemo and the channel closed at
# once. So the app STAYS installed; uninstalling would hide the defect rather than fix it.
#
# It could not be turned OFF either. CoreBluetooth state restoration relaunches it on any BLE event,
# so terminating it is futile and it was observed back within seconds every time. That made the
# decisive experiment (a device publishing ONE hop service, then a SECOND appearing) impossible to
# stage. The app now carries a PERSISTED dormant switch, checked before any CB manager is
# constructed, so it stays down across the relaunch. These drive it.
tk_blelab() {               # tk_blelab <id> <on|off>
  local id="$1" want="$2" handle en ok b
  case "$want" in
    on|true|1)   en=true;;
    off|false|0) en=false;;
    *) echo "testkit: tk_blelab: want must be on|off, got '$want'" >&2; return 2;;
  esac
  [ "$(dev_platform "$id")" = apple ] || { echo "testkit: tk_blelab: iOS only, BLE Lab is not installed on Android" >&2; return 2; }
  handle=$(dev_handle "$id")
  ok=1
  # Try both bundle ids: the tree builds sh.hopme.blelab, older installs carry co.hopmesh.blelab.
  for b in sh.hopme.blelab co.hopmesh.blelab; do
    if dctlx device process launch --device "$handle" --activate \
         --payload-url "blelab://radio?enabled=$en" "$b" >/dev/null 2>&1; then ok=0; break; fi
  done
  [ "$ok" -eq 0 ] || { echo "testkit: tk_blelab $id: could not reach BLE Lab under either bundle id" >&2; return 1; }
  sleep 2
  echo "testkit: tk_blelab $id radio=$en (verify with tk blelabstate $id)"
}

# Is BLE Lab running, and if so is it dormant? A running-but-DORMANT process is a PASS: the switch
# is checked before any CB manager exists, so a relaunched dormant process holds no radio.
tk_blelabstate() {          # tk_blelabstate <id>
  local id="$1" handle n
  handle=$(dev_handle "$id")
  n=$(dctlx device info processes --device "$handle" 2>/dev/null | grep -ci blelab)
  echo "blelab_procs=$n (running-but-dormant is expected; its log says DORMANT radio=off)"
}

# --- verify receipt on the RECEIVER -----------------------------------------
# quality-net-06: Android's files/messages.json is a DEBOUNCED export that lags in-memory delivery by
# >90s, so polling it alone false-negatives a real delivery inside the poll window. The driver now
# logs "HOPAUTO received ... text=<marker>" to logcat the instant a message lands, so we consult
# logcat FIRST (immediate, authoritative) and fall back to the json only if logcat has no hit (e.g.
# the buffer was cleared). iOS is unchanged (automation.json is its only signal here).
tk_verify() {               # tk_verify <to-id> <marker>  -> prints count (>0 = received)
  local id="$1" mark="$2" plat handle n
  plat=$(dev_platform "$id"); handle=$(dev_handle "$id")
  if [ "$plat" = android ]; then
    # 1) logcat HOPAUTO received line (no export lag). Count distinct receipts of this marker.
    n=$(adbx -s "$handle" logcat -d -s HOPLOG 2>/dev/null \
      | grep -F "HOPAUTO received" | grep -Fc -- "text=$mark" 2>/dev/null || echo 0)
    if [ "${n:-0}" -gt 0 ] 2>/dev/null; then echo "$n"; return; fi
    # 2) fall back to the (lagging) json mirror.
    adbx -s "$handle" shell run-as "$BUNDLE" cat files/messages.json 2>/dev/null \
      | python3 -c "import json,sys
try:
 d=json.load(sys.stdin); ms=d if isinstance(d,list) else d.get('messages',[])
 print(sum(1 for m in ms if m.get('incoming') and '$mark' in str(m.get('text',''))))
except: print(0)"
  else
    tk_pull_automation "$id" >/dev/null 2>&1
    python3 -c "import json
try:
 d=json.load(open('$WORK/$id.automation.json')); print(sum(1 for r in d.get('rx',[]) if '$mark' in str(r.get('text',''))))
except: print(0)" 2>/dev/null || echo 0
  fi
}

# --- verify END-TO-END delivery ack on the SENDER ---------------------------
# quality-net-06: same lag applies to the sender's delivered=true flag in messages.json. The driver
# now logs "HOPAUTO delivered ... text=<marker>" the instant the node reports the end-to-end ACK, so
# trust that signal first (it is the crypto delivery proof, unlagged) and fall back to the json.
tk_delivered() {            # tk_delivered <from-id> <marker>  -> "true"/"false"
  local id="$1" mark="$2" plat handle
  plat=$(dev_platform "$id"); handle=$(dev_handle "$id")
  if [ "$plat" = android ]; then
    # 1) logcat HOPAUTO delivered line (the unlagged end-to-end ACK signal).
    if adbx -s "$handle" logcat -d -s HOPLOG 2>/dev/null \
      | grep -F "HOPAUTO delivered" | grep -Fq -- "text=$mark"; then echo true; return; fi
    # 2) fall back to the (lagging) json mirror's delivered=true flag.
    adbx -s "$handle" shell run-as "$BUNDLE" cat files/messages.json 2>/dev/null \
      | python3 -c "import json,sys
try:
 d=json.load(sys.stdin); ms=d if isinstance(d,list) else d.get('messages',[])
 print('true' if any((not m.get('incoming')) and '$mark' in str(m.get('text','')) and m.get('delivered') for m in ms) else 'false')
except: print('false')"
  else
    tk_pull_automation "$id" >/dev/null 2>&1
    python3 -c "import json
try:
 d=json.load(open('$WORK/$id.automation.json')); print('true' if any('$mark' in str(t.get('text','')) and t.get('delivered') for t in d.get('tx',[])) else 'false')
except: print('false')" 2>/dev/null || echo false
  fi
}

# --- foreground / background -------------------------------------------------
tk_fg() {                   # tk_fg <id>
  local id="$1" plat handle; plat=$(dev_platform "$id"); handle=$(dev_handle "$id")
  if [ "$plat" = android ]; then
    adbx -s "$handle" shell monkey -p "$BUNDLE" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
  else
    dctlx device process launch --device "$handle" "$BUNDLE" >/dev/null 2>&1
  fi
}
tk_bg() {                   # tk_bg <id>  (push Hop to background, keep it running)
  local id="$1" plat handle; plat=$(dev_platform "$id"); handle=$(dev_handle "$id")
  if [ "$plat" = android ]; then
    adbx -s "$handle" shell input keyevent KEYCODE_HOME >/dev/null 2>&1
  else
    # launch Settings -> backgrounds HopDemo (it keeps running w/ BLE bg modes)
    dctlx device process launch --device "$handle" com.apple.Preferences >/dev/null 2>&1
  fi
}

# --- log capture -------------------------------------------------------------
tk_logclear() {             # tk_logclear <id>  (android only; ios best-effort)
  local id="$1" plat handle; plat=$(dev_platform "$id"); handle=$(dev_handle "$id")
  [ "$plat" = android ] && adbx -s "$handle" logcat -c >/dev/null 2>&1
}
tk_logcap() {               # tk_logcap <id> <outfile>  (android: dump HOPLOG/HOPCORE)
  local id="$1" out="$2" plat handle; plat=$(dev_platform "$id"); handle=$(dev_handle "$id")
  [ "$plat" = android ] && adbx -s "$handle" logcat -d -s HOPLOG HOPCORE 2>/dev/null > "$out"
}
tk_nodestate() {            # tk_nodestate <id>  -> last NODESTATE line (android)
  local id="$1" plat handle; plat=$(dev_platform "$id"); handle=$(dev_handle "$id")
  [ "$plat" = android ] && adbx -s "$handle" logcat -d -s HOPLOG 2>/dev/null | grep NODESTATE | tail -1
}
