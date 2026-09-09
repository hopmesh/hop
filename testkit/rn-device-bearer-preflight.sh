#!/usr/bin/env bash
# Capture the physical-device inventory and stop before any bearer proof if the React Native
# consumer cannot build and install with the native Hop SDK plus BLE and LAN AARs.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
RUN_ID="${1:-$(date -u +%Y%m%dT%H%M%SZ)}"
OUT="${TK_RESULTS_DIR:-$HERE/results/rn-device-bearer-$RUN_ID}"
PIXEL="${TK_RN_PIXEL:-34241FDH2004KR}"
IPHONE="${TK_RN_IPHONE:-0280AC9F-551E-55DA-A969-62D4242A003C}"
APP="$ROOT/apps/react-native/HopDemo"
MAVEN="$ROOT/sdk/react-native/android/.hop-maven"
APK="$APP/android/app/build/outputs/apk/debug/app-debug.apk"
ADDRS="$HERE/addrs.env"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

if [[ -f "$ADDRS" ]]; then
  cp "$ADDRS" "$OUT/addrs.env.before"
  had_addrs=true
else
  had_addrs=false
fi
restore_addrs() {
  local rc=$?
  if [[ "$had_addrs" == true ]]; then
    if ! cmp -s "$OUT/addrs.env.before" "$ADDRS"; then
      cp "$OUT/addrs.env.before" "$ADDRS"
    fi
  elif [[ -e "$ADDRS" ]]; then
    rm -f "$ADDRS"
  fi
  exit "$rc"
}
trap restore_addrs EXIT

capture() {
  local name="$1"
  shift
  printf '%q ' "$@" > "$OUT/$name.command"
  printf '\n' >> "$OUT/$name.command"
  "$@" > "$OUT/$name.log" 2>&1
}

write_summary() {
  local stage="$1" result="$2" code="$3" reason="$4"
  python3 - "$OUT" "$ROOT" "$RUN_ID" "$stage" "$result" "$code" "$reason" "$PIXEL" "$IPHONE" <<'PY'
import datetime
import json
import pathlib
import re
import sys

out = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
run_id, stage, result, code, reason, pixel, iphone = sys.argv[3:10]

def text(name):
    path = out / name
    return path.read_text(errors="replace") if path.exists() else ""

def command(name):
    return text(name).strip()

def evidence(pattern, body):
    found = []
    for line in body.splitlines():
        if re.search(pattern, line) and line.strip() not in found:
            found.append(line.strip())
    return found

bootstrap = text("build-aar-dev.log")
consumer = text("assemble-debug.log")
install = text("install.log")
sha = text("apk-sha256.log").strip().split()
blocked = result != "exercised"
record = {
    "schema": "hop.rn-device-bearer-proof.v1",
    "runId": run_id,
    "recordedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "snapshot": command("snapshot.log"),
    "devices": {
        "adb": {
            "command": command("adb-devices.command"),
            "output": text("adb-devices.log").splitlines(),
        },
        "devicectl": {
            "command": command("apple-devices.command"),
            "output": text("apple-devices.log").splitlines(),
        },
        "iphoneLock": {
            "command": command("iphone-lock.command"),
            "exitCode": int(command("iphone-lock.exit") or "0"),
            "output": text("iphone-lock.log").splitlines(),
        },
    },
    "build": {
        "bootstrap": {
            "command": command("build-aar-dev.command"),
            "exitCode": int(command("build-aar-dev.exit") or "0"),
            "evidence": evidence(r"build-aar-dev: (sh\.hop|verified|published 3 artifacts)|Building (arm64-v8a|armeabi-v7a|x86|x86_64)", bootstrap),
            "log": str((out / "build-aar-dev.log").relative_to(root)),
        },
        "consumer": {
            "command": command("assemble-debug.command"),
            "exitCode": int(command("assemble-debug.exit") or "0"),
            "evidence": evidence(r"Could not find sh\.hop\.bearers:|incompatible version of Kotlin|uses-sdk:minSdkVersion|Searched in the following locations:|BUILD (SUCCESSFUL|FAILED)", consumer),
            "log": str((out / "assemble-debug.log").relative_to(root)),
        },
        "apkSha256": sha[0] if sha else None,
        "install": {
            "command": command("install.command") or None,
            "exitCode": int(command("install.exit")) if command("install.exit") else None,
            "evidence": evidence(r"Success|Failure", install),
        },
    },
    "stop": {"stage": stage, "exitCode": int(code), "reason": reason},
    "classes": [
        {
            "class": "hardware",
            "bearer": bearer,
            "verdict": "blocked" if blocked else "exercised",
            "reason": reason if blocked else None,
            "nonce": None,
            "senderAck": None,
            "receiverLog": None,
        }
        for bearer in ("ble", "lan")
    ],
}
(out / "summary.json").write_text(json.dumps(record, indent=2) + "\n")
print(json.dumps(record, indent=2))
PY
}

printf '%s\n' "$(git -C "$ROOT" rev-parse HEAD)" > "$OUT/snapshot.log"

capture adb-devices adb devices -l
capture apple-devices xcrun devicectl list devices
capture iphone-lock xcrun devicectl device info lockState --device "$IPHONE"
printf '%s\n' "$?" > "$OUT/iphone-lock.exit"

capture build-aar-dev mise exec -- bash "$ROOT/sdk/android/build-aar-dev.sh" --repository "$MAVEN"
build_rc=$?
printf '%s\n' "$build_rc" > "$OUT/build-aar-dev.exit"
if [[ "$build_rc" -ne 0 ]]; then
  reason="native Android artifact bootstrap failed; BLE and LAN device sends were not attempted"
  write_summary bootstrap blocked "$build_rc" "$reason"
  exit "$build_rc"
fi

capture npm-ci bash -lc "cd '$APP' && npm ci"
npm_rc=$?
printf '%s\n' "$npm_rc" > "$OUT/npm-ci.exit"
if [[ "$npm_rc" -ne 0 ]]; then
  reason="React Native consumer dependency install failed; BLE and LAN device sends were not attempted"
  write_summary npm-ci blocked "$npm_rc" "$reason"
  exit "$npm_rc"
fi

export ANDROID_HOME="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$ANDROID_HOME}"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}"
export PATH="$JAVA_HOME/bin:$HOME/.cargo/bin:$PATH"
export HOP_MAVEN_REPOSITORY="$MAVEN"
capture assemble-debug bash -lc "cd '$APP' && ./android/gradlew -p android :app:assembleDebug --stacktrace --no-daemon"
assemble_rc=$?
printf '%s\n' "$assemble_rc" > "$OUT/assemble-debug.exit"
if [[ "$assemble_rc" -ne 0 ]]; then
  reason="React Native native consumer did not assemble an APK; BLE and LAN device sends were not attempted"
  write_summary assemble-debug blocked "$assemble_rc" "$reason"
  exit "$assemble_rc"
fi

capture apk-sha256 shasum -a 256 "$APK"
sha_rc=$?
printf '%s\n' "$sha_rc" > "$OUT/apk-sha256.exit"
if [[ "$sha_rc" -ne 0 ]]; then
  reason="React Native build reported success but the APK could not be hashed; installation and bearer sends were not attempted"
  write_summary apk-sha256 blocked "$sha_rc" "$reason"
  exit "$sha_rc"
fi

capture install adb -s "$PIXEL" install -r "$APK"
install_rc=$?
printf '%s\n' "$install_rc" > "$OUT/install.exit"
if [[ "$install_rc" -ne 0 ]]; then
  reason="React Native APK installation failed; BLE and LAN device sends were not attempted"
  write_summary install blocked "$install_rc" "$reason"
  exit "$install_rc"
fi

# Whitelist com.hopdemo from battery optimization and set standby bucket active so
# Android NetworkPolicyManagerService does not drop TCP traffic in APP_STANDBY/APP_BACKGROUND
# on a passcode-locked / sleeping device.
capture deviceidle-whitelist adb -s "$PIXEL" shell dumpsys deviceidle whitelist +com.hopdemo
capture standby-bucket adb -s "$PIXEL" shell am set-standby-bucket com.hopdemo active

reason="build and install passed; this preflight does not claim bearer delivery without a unique nonce, sender ACK, and receiver log"
write_summary ready blocked 3 "$reason"
exit 3
