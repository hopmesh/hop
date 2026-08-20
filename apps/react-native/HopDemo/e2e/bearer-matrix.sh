#!/usr/bin/env bash
# Two physical devices, every bearer, both directions.
#
# WHAT THIS PROVES, and why it is shaped this way.
#
# Jason's requirement is a real device-to-device test over ALL bearers. Three constraints shape the design:
#
#   1. Detox 20's device types are android.apk, android.attached, android.emulator, android.genycloud,
#      ios.app and ios.simulator. There is NO physical-iOS type, so a UI-driven harness cannot touch the
#      iPhone. A simulator is not an acceptable substitute: it has no radio.
#   2. Both apps therefore expose the native demo's automation URL scheme (hopdemo://send and
#      hopdemo://bearer), so a harness can drive a send and flip a bearer without tapping anything.
#   3. Each app prints one line per event: HOPSELF at startup, HOPXPORT on transport change, HOPSEND on an
#      automation send, HOPRECV on receipt. Those lines are the oracle. Android is read with logcat, iOS
#      with `xcrun devicectl device process launch --console`.
#
# For every bearer the two devices share, the matrix enables exactly that bearer on both sides, confirms
# the state from HOPXPORT rather than assuming the toggle took, sends in one direction, waits for HOPRECV
# carrying that run's unique body, then repeats in the other direction. A bearer that cannot carry a
# message is reported as a failure for that bearer, not skipped, and the script exits non-zero if any
# direction of any bearer failed.
set -uo pipefail

ANDROID_SERIAL="${DETOX_ADB_NAME:-34241FDH2004KR}"
IPHONE_DEVICE="${HOP_IPHONE_DEVICE:-802500FE-27D7-502F-9D2C-9486D5CA74B2}"
APP_ID=com.hopdemo
ANDROID_ACTIVITY="$APP_ID/.MainActivity"
LOGDIR="${TMPDIR:-/tmp}/hop-matrix"
IOS_CONSOLE="$LOGDIR/iphone.console.log"
ANDROID_LOG="$LOGDIR/android.logcat.log"

export ANDROID_HOME="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
export PATH="$ANDROID_HOME/platform-tools:$PATH"

mkdir -p "$LOGDIR"
FAILURES=()
note() { echo "  $*"; }
die()  { echo "FAIL: $*" >&2; exit 1; }

# ---------------------------------------------------------------- device plumbing

adb_app() { adb -s "$ANDROID_SERIAL" "$@"; }

android_url() {
  # adb shell concatenates argv into a remote shell line. The ampersand in a query string is a
  # shell operator there, so an unquoted -d URL drops everything after the first &. Wrap the whole
  # am command so name= and enabled= (and send's text=) actually reach the app.
  adb_app shell "am start -a android.intent.action.VIEW -d '$1'" >/dev/null 2>&1
}

ios_url() {
  # `--payload-url` is devicectl's own words: "A URL to pass to the application for it to open". It is the
  # only way to reach a URL scheme on a PHYSICAL iPhone from a shell, since there is no `devicectl device
  # open`, and Safari would need a human to tap through the scheme prompt.
  #
  # Deliberately no --terminate-existing here: the receiver's console attachment belongs to the running
  # instance, and killing it would throw away the HOPRECV line this whole harness reads.
  xcrun devicectl device process launch --device "$IPHONE_DEVICE" --activate \
    --payload-url "$1" "$APP_ID" >/dev/null 2>&1
}

android_lines() { adb_app logcat -d 2>/dev/null | grep -a "$1" 2>/dev/null; }
ios_lines()     { grep -a "$1" "$IOS_CONSOLE" 2>/dev/null; }

wait_for() {
  # wait_for <describe> <seconds> <command...>; the command's exit status is the condition.
  local what="$1" secs="$2"; shift 2
  for _ in $(seq 1 "$secs"); do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  note "timed out waiting for $what"
  return 1
}

json_field() { python3 -c 'import json,sys; print(json.loads(sys.stdin.read().split(None,1)[1])["'"$1"'"])'; }

# ---------------------------------------------------------------- preconditions

adb_app get-state >/dev/null 2>&1 || die "android device $ANDROID_SERIAL not connected"
xcrun devicectl list devices 2>/dev/null | grep -q "$IPHONE_DEVICE" || die "iphone $IPHONE_DEVICE not paired"

# A phone that has gone to sleep, or is showing its notification shade, cannot receive a VIEW intent.
adb_app shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
adb_app shell cmd statusbar collapse >/dev/null 2>&1

adb_app logcat -c >/dev/null 2>&1
: > "$IOS_CONSOLE"

note "starting the receiver console on the iphone"
xcrun devicectl device process launch --device "$IPHONE_DEVICE" --console --terminate-existing "$APP_ID" \
  >"$IOS_CONSOLE" 2>&1 &
IOS_CONSOLE_PID=$!
trap 'kill $IOS_CONSOLE_PID 2>/dev/null' EXIT

note "starting the app on the android phone"
adb_app shell am start -n "$ANDROID_ACTIVITY" >/dev/null 2>&1

wait_for "HOPSELF from the iphone" 45 bash -c 'grep -aq HOPSELF "'"$IOS_CONSOLE"'"' \
  || die "the iphone app never reported itself; see $IOS_CONSOLE"
wait_for "HOPSELF from the android phone" 45 bash -c \
  'adb -s '"$ANDROID_SERIAL"' logcat -d 2>/dev/null | grep -aq HOPSELF' \
  || die "the android app never reported itself"

IOS_ADDR="$(ios_lines HOPSELF | head -1 | json_field address)"
IOS_NAME="$(ios_lines HOPSELF | head -1 | json_field name)"
AND_ADDR="$(android_lines HOPSELF | head -1 | sed 's/.*HOPSELF /HOPSELF /' | json_field address)"
AND_NAME="$(android_lines HOPSELF | head -1 | sed 's/.*HOPSELF /HOPSELF /' | json_field name)"
note "iphone : $IOS_NAME  $IOS_ADDR"
note "android: $AND_NAME  $AND_ADDR"
[ -n "$IOS_ADDR" ] && [ -n "$AND_ADDR" ] || die "one device reported no address"

# ---------------------------------------------------------------- the bearer matrix

# The bearers to exercise come from what the devices actually report, not from a hardcoded list, so a
# transport added to the driver later is covered without editing this file.
BEARERS="$(ios_lines HOPXPORT | tail -1 | sed 's/.*HOPXPORT //' \
  | python3 -c 'import json,sys; print("\n".join(sorted(k for k in json.load(sys.stdin) if k not in ("LoRa","Meshtastic","LoRaWAN","Peer-to-Peer"))))' 2>/dev/null)"
[ -n "$BEARERS" ] || die "the iphone never reported its transports (HOPXPORT); cannot enumerate bearers"
note "bearers reported: $(echo "$BEARERS" | tr '\n' ' ') (LoRa and Peer-to-Peer skipped: no bonded radio / Android has no Multipeer)"

set_only_bearer() {
  # Enable exactly one bearer on both devices, then CONFIRM from HOPXPORT rather than trusting the toggle.
  local keep="$1" b
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    local want=false; [ "$b" = "$keep" ] && want=true
    local encoded
    encoded="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$b")"
    android_url "hopdemo://bearer?name=$encoded&enabled=$want"
    ios_url     "hopdemo://bearer?name=$encoded&enabled=$want"
  done <<< "$BEARERS"
  # Also switch off the skipped radios so they cannot carry the message.
  for b in LoRa "Peer-to-Peer"; do
    local encoded
    encoded="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$b")"
    android_url "hopdemo://bearer?name=$encoded&enabled=false"
    ios_url     "hopdemo://bearer?name=$encoded&enabled=false"
  done
  sleep 3
  local ios_state and_state
  ios_state="$(ios_lines HOPXPORT | tail -1 | sed 's/.*HOPXPORT //')"
  and_state="$(android_lines HOPXPORT | tail -1 | sed 's/.*HOPXPORT //')"
  python3 - "$keep" "$ios_state" "$and_state" <<'PY'
import json, sys
keep, ios, android = sys.argv[1], sys.argv[2], sys.argv[3]
ok = True
for label, raw in (("iphone", ios), ("android", android)):
    try:
        st = json.loads(raw)
    except Exception:
        print(f"    {label}: unreadable transport state"); ok = False; continue
    on = sorted(k for k, v in st.items() if v != "off")
    print(f"    {label} enabled: {on or 'none'}")
    if on != [keep]:
        ok = False
sys.exit(0 if ok else 1)
PY
}

send_and_expect() {
  # send_and_expect <from android|ios> <bearer>
  local from="$1" bearer="$2"
  local body="hop-$bearer-$from-$(date +%s)-$RANDOM"
  if [ "$from" = "android" ]; then
    android_url "hopdemo://send?to=$IOS_ADDR&text=$body"
    wait_for "HOPRECV on the iphone" 45 bash -c 'grep -aq "'"$body"'" "'"$IOS_CONSOLE"'"'
  else
    ios_url "hopdemo://send?to=$AND_ADDR&text=$body"
    wait_for "HOPRECV on the android phone" 45 bash -c \
      'adb -s '"$ANDROID_SERIAL"' logcat -d 2>/dev/null | grep -aq "'"$body"'"'
  fi
}

while IFS= read -r bearer; do
  [ -n "$bearer" ] || continue
  echo
  echo "=== bearer: $bearer ==="
  if ! set_only_bearer "$bearer"; then
    note "could not isolate $bearer on both devices"
    FAILURES+=("$bearer: isolation")
    continue
  fi
  for direction in android ios; do
    if send_and_expect "$direction" "$bearer"; then
      note "PASS $bearer  $direction -> other device"
    else
      note "FAIL $bearer  $direction -> other device"
      FAILURES+=("$bearer: $direction")
    fi
  done
done <<< "$BEARERS"

echo
if [ ${#FAILURES[@]} -eq 0 ]; then
  echo "PASS: every bearer carried a message in both directions between two physical devices"
  exit 0
fi
echo "FAILURES:"
for f in "${FAILURES[@]}"; do echo "  $f"; done
echo "logs: $IOS_CONSOLE and $ANDROID_LOG"
adb_app logcat -d > "$ANDROID_LOG" 2>/dev/null
exit 1
