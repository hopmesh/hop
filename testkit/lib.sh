#!/usr/bin/env bash
# Hop test harness primitives. Uniform send/verify/fg-bg/log across Android (adb) and iOS (devicectl).
#   Android send : hopdemo://send deep link (am start)         — fires bearer.sendTo, no UI taps
#   iOS send     : HOP_AUTO launch env (devicectl)             — app sends ~3s after (re)launch
#   Verify rx    : Android files/messages.json ; iOS Documents/automation.json (.rx)
#   Verify ack   : sender side delivered=true (END-TO-END crypto proof the dest received it)
#   bg/fg        : Android KEYCODE_HOME / monkey ; iOS launch Settings / launch app
#
# Source devices.sh first. addrs.env (name->addr) is produced by refresh-addrs.sh.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/devices.sh"
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
tk_send() {                 # tk_send <from-id> <to-addr> <marker>
  local id="$1" to="$2" mark="$3" plat handle
  plat=$(dev_platform "$id"); handle=$(dev_handle "$id")
  if [ "$plat" = android ]; then
    adbx -s "$handle" shell "am start -a android.intent.action.VIEW -d 'hopdemo://send?to=$to&text=$mark'" >/dev/null 2>&1
    # Android coalesces VIEW intents fired back-to-back (LAUNCH_MULTIPLE) and silently drops
    # one when sends are <~100ms apart. Settle between consecutive sends so each registers.
    sleep 0.7
  else
    # cold relaunch with the send command in the env; the app fires it ~3s post-launch.
    dctlx device process launch --device "$handle" --terminate-existing \
      --environment-variables "{\"HOP_AUTO\":\"send|$to|$mark\"}" "$BUNDLE" >/dev/null 2>&1
  fi
}

# --- verify receipt on the RECEIVER -----------------------------------------
tk_verify() {               # tk_verify <to-id> <marker>  -> prints count (>0 = received)
  local id="$1" mark="$2" plat handle
  plat=$(dev_platform "$id"); handle=$(dev_handle "$id")
  if [ "$plat" = android ]; then
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
tk_delivered() {            # tk_delivered <from-id> <marker>  -> "true"/"false"
  local id="$1" mark="$2" plat handle
  plat=$(dev_platform "$id"); handle=$(dev_handle "$id")
  if [ "$plat" = android ]; then
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
